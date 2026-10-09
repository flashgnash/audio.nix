#!/usr/bin/env python3
"""audio-balance — per-app OUTPUT loudness balancing (+ spike limiter).

When output balancing is enabled, each running app's audio is routed through one
of a fixed pool of pre-declared filter-chain sinks (`applvl.<n>`, defined in
flakes/audio/pipewire.nix) that LUFS-levels it to a common target and brick-wall
limits transients — so every app sits at the same perceived loudness and nobody
yelling down a mic can deafen you.

Design (why this is safe and lossless):
  * The heavy DSP is STATIC — declared once at boot as ordinary, proven-stable
    filter-chains (same mechanism as rnnoise_source). This daemon NEVER creates
    or destroys graph nodes; it only *assigns* an app to a free slot by moving
    its sink-inputs (`pactl move-sink-input`), which is fully reversible and
    exactly what pavucontrol does. So it cannot wedge the graph.
  * All gain stays in PipeWire's 32-bit float domain: the app's own volume, the
    leveler gain and the limiter collapse to one float multiply, and the limiter
    guarantees the signal can't clip the single float->int conversion at the DAC.
    The user's manual per-app volume (the sink-input volume) is left untouched —
    the balance gain lives INSIDE the filter-chain, a separate float multiply, so
    enabling balancing never clobbers existing per-app volume settings.

This daemon also owns per-stream FX pinning (audio-streamfx): rules in
~/.config/audio-streamfx/rules.json pin an app's streams onto one of the static
`strmfx.<preset>` filter sinks (99-stream-fx in pipewire.nix). It lives here —
not in a separate daemon — because exactly ONE mover may own sink-input
placement, or the two reconcilers race each other over the same streams.
Fx-pinned streams are excluded from the balance pool and published as extra
rows (with an "fx" field) so the gauges can show/drive them the same way.

Voice-chat ducking (audio-duck) also lives here, for the same single-mover
reason: ducking acts on the very chains/streams this reconcile
owns. While speech is detected on a voice app's playback (vesktop for now;
per-user discordpeer.* bridges are picked up automatically once present),
every OTHER stream is dipped by duck_db decibels and restored after hold_ms
of silence. For streams on a balance/fx chain the dip is its OWN GAIN LAYER:
a dedicated duck mixer stage inside the static filter-chain (pipewire.nix),
set via pw-cli set-param exactly like the rnnoise dry/wet bypass. The user's
volumes — sink-input AND .out bridge trim — are never touched, so the gauge
stays fully adjustable mid-duck and trims can't be corrupted. Only unmanaged
streams (balance off / pool overflow), which have no chain to host a layer,
fall back to dipping their own sink-input volume (saved and restored through
pulse's CUBIC pct scale, 10^(-dB/60); a user change mid-duck wins over the
restore). Transitions are RAMPED (~120 ms down so the dip lands with the
voice, ~500 ms up so inter-sentence gaps don't pump the music; speech
resuming mid-release turns the slide around from wherever it is). Config
lives at ~/.config/audio-duck/config.json (audio-duck CLI, tools.nix);
priority (duck-triggering) apps are its voice_apps list.

The muffle gate (audio-duck muffle) rides the same detectors: hot blocks on a
voice stream are classified direct-vs-muffled by high-band share, muffled-only
activity stops triggering the duck AND is dipped on the voice chains' own
duck-gain stage (idle for voice chains otherwise). See the block comment above
_muffle for the full mechanism.

The daemon is event-driven (pactl subscribe), never polls the graph. It publishes
the applied per-slot gain for the bar to draw the "balance adjustment" arc:
  ~/.local/state/qs-audio/balance.json
  { "output": [ {"key": "<binary>", "ids": [<sink-input#>...], "gain": <pct>}, ...],
    "input":  [ ... ] }
gain is the leveler's applied gain as a percentage (100 = unity / no change).
"""

import array
import fcntl
import json
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time

PACTL = os.environ.get("PACTL", "pactl")
PW_DUMP = os.environ.get("PW_DUMP", "pw-dump")
PW_CLI = os.environ.get("PW_CLI", "pw-cli")
PAREC = os.environ.get("PAREC", "parec")
MIC_INUSE = os.environ.get("MIC_INUSE", "audio-mic-inuse")
DBUS_MONITOR = os.environ.get("DBUS_MONITOR", "dbus-monitor")
BUSCTL = os.environ.get("BUSCTL", "busctl")

# OUTPUT arc display clamps. The applied gain is MEASURED per slot (post-filter
# loudness minus pre-filter loudness — see the reader pair below); these only
# bound what the blue arc shows against measurement noise.
OUTPUT_MAX_AMP_DB = 18.0     # plugin max amp is +12; headroom for meter noise
OUTPUT_MIN_GAIN_DB = -24.0   # how far we show attenuation of loud streams

CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "audio-balance", "config.json",
)
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
    "qs-audio",
)
STATE_FILE = os.path.join(STATE_DIR, "balance.json")
# Persistent per-APP post-leveler trims ({app key: pct}). These are the user's
# gauge settings WHILE balancing is on (the applvl.<n>.out bridge volume) —
# deliberately separate from the apps' own sink-input volumes, which the
# balancer never touches. Restored whenever the app lands on a slot, so trims
# survive daemon/PipeWire restarts and slot reshuffles.
TRIMS_FILE = os.path.join(STATE_DIR, "balance-trims.json")

# Must match the pool size declared in flakes/audio/pipewire.nix (99-app-balance).
NSLOTS = int(os.environ.get("BALANCE_SLOTS", "4"))
SLOT_SINKS = ["applvl.%d" % i for i in range(NSLOTS)]

# Per-stream FX presets: pinnable filter-chain sinks (99-stream-fx in
# pipewire.nix). Rules ({app key: preset}) are written by audio-streamfx; this
# daemon owns ALL sink-input placement, so fx pinning lives here too — a
# separate mover would race the balance reconcile over the same streams.
# FX pinning works regardless of whether balancing is enabled; fx-pinned
# streams are excluded from the balance pool (the voice preset carries its own
# leveler).
FX_CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "audio-streamfx", "rules.json",
)
FX_PRESETS = {"voice": "strmfx.voice", "bass": "strmfx.bass"}
FX_SINKS = set(FX_PRESETS.values())

# Streams we must never try to balance: the balance/fx sinks' own outputs, and
# the other virtual plumbing that shows up as sink-inputs. `soundboard` is the
# soundboard's mpv daemon — its output ports are manually pw-link'ed into mic
# capture streams (scripts/soundboard.nix); pooling it onto an applvl slot
# re-routes it to the speakers and sweeps those injection links (2026-10-05).
_SKIP_STREAM_RE = re.compile(r"^(applvl\.|strmfx\.|tailnet-|combined_|soundboard)")

# Voice-chat ducking config (audio-duck CLI). Disabled is the default.
DUCK_CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "audio-duck", "config.json",
)


def load_duck_config():
    """duck_db is how far other audio dips while voice is active. factor is
    the pre-computed pulse-% multiplier: pactl percentages are CUBIC in
    amplitude (amp = (pct/100)^3), so an X dB dip is pct * 10^(-X/60)."""
    cfg = {"enabled": False, "duck_db": 8.0, "threshold_db": -40.0,
           "hold_ms": 900, "voice_apps": ["vesktop"],
           "adaptive": True, "margin_db": 1.0,
           "mic_trigger": False, "mic_threshold_db": -35.0,
           "muffle_mode": "off", "muffle_hf_db": -16.0,
           "muffle_gate_db": 24.0, "muffle_engage_ms": 350,
           "muffle_release_ms": 700, "muffle_direct_ms": 700}
    try:
        with open(DUCK_CONFIG) as f:
            c = json.load(f)
        cfg["enabled"] = bool(c.get("enabled", False))
        cfg["duck_db"] = max(1.0, min(30.0, float(c.get("duck_db", 8.0))))
        cfg["threshold_db"] = float(c.get("threshold_db", -40.0))
        cfg["hold_ms"] = max(100, int(c.get("hold_ms", 900)))
        cfg["voice_apps"] = [str(a).lower()
                             for a in c.get("voice_apps", ["vesktop"])] or ["vesktop"]
        # Adaptive dip: size each chain's dip from LIVE loudness so ducked
        # audio lands margin_db below the quietest priority source (~1 dB ≈
        # 10% quieter). duck_db stays the fallback when measurements are
        # missing. Attenuation only — never a boost.
        cfg["adaptive"] = bool(c.get("adaptive", True))
        cfg["margin_db"] = max(0.0, min(12.0, float(c.get("margin_db", 1.0))))
        # Near-end trigger: duck when the USER speaks (detected on the
        # rnnoise_source output), not just when far-end voice plays. Less
        # music into the mic = less for the AEC's residual suppressor to
        # mangle during double-talk (2026-10-05).
        cfg["mic_trigger"] = bool(c.get("mic_trigger", False))
        # -35 default: impulsive transients that survive RNNoise (chair
        # creaks, desk knocks) sit lower than on-mic speech; -40 tripped
        # on them (2026-10-08).
        cfg["mic_threshold_db"] = float(c.get("mic_threshold_db", -35.0))
        # Own-speech dips are DEEPER than far-end ones by default: the point
        # is keeping room music out of the mic (and the AEC's residual
        # suppressor), not polite listening balance — 8 dB was barely
        # audible on the mic path (2026-10-05).
        cfg["mic_duck_db"] = max(1.0, min(30.0, float(c.get("mic_duck_db", 15.0))))
        # Shorter hold for the own-speech trigger: 900 ms (tuned for far-end
        # speech) made the restore feel laggy after the user stops talking
        # (2026-10-05). Own speech is detected locally with ~30 ms lag, so a
        # tighter hold still bridges word gaps; the slow release glide
        # covers sentence gaps.
        cfg["mic_hold_ms"] = max(100, int(c.get("mic_hold_ms", 450)))
        # Muffle gate (see the _muffle block comment): "off" = plain RMS gate,
        # "log" = classify + journal only (threshold tuning, behaviour
        # unchanged), "on" = muffled-only blocks neither trigger the duck nor
        # stay audible. muffle_hf_db is the high-band share (dB, negative) a
        # hot block needs to count as direct speech.
        m = str(c.get("muffle_mode", "off")).lower()
        cfg["muffle_mode"] = m if m in ("off", "log", "on") else "off"
        cfg["muffle_hf_db"] = max(-40.0, min(0.0,
                                             float(c.get("muffle_hf_db", -16.0))))
        cfg["muffle_gate_db"] = max(3.0, min(60.0,
                                             float(c.get("muffle_gate_db", 24.0))))
        cfg["muffle_engage_ms"] = max(100, int(c.get("muffle_engage_ms", 350)))
        cfg["muffle_release_ms"] = max(200, int(c.get("muffle_release_ms", 700)))
        cfg["muffle_direct_ms"] = max(200, int(c.get("muffle_direct_ms", 700)))
    except Exception:
        pass
    cfg["factor"] = 10.0 ** (-cfg["duck_db"] / 60.0)      # pulse-% (cubic) domain
    cfg["factor_lin"] = 10.0 ** (-cfg["duck_db"] / 20.0)  # linear, for chain gains
    return cfg


def sh(*args, timeout=10):
    try:
        return subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    except Exception as e:  # noqa: BLE001 — never let a scan crash the daemon
        return subprocess.CompletedProcess(args, 1, "", str(e))


# ------------------------------------------------------------------- config
def load_config():
    try:
        with open(CONFIG) as f:
            c = json.load(f)
        return {
            "output_enabled": bool(c.get("output_enabled", False)),
            "input_enabled": bool(c.get("input_enabled", False)),
        }
    except Exception:
        return {"output_enabled": False, "input_enabled": False}


def load_fx_rules():
    """{app key: preset} — only presets we actually have a sink for."""
    try:
        with open(FX_CONFIG) as f:
            c = json.load(f)
        return {str(k).lower(): str(v) for k, v in c.items()
                if str(v) in FX_PRESETS}
    except Exception:
        return {}


# ------------------------------------------------------------------- pactl parse
def default_sink():
    r = sh(PACTL, "get-default-sink")
    return r.stdout.strip() if r.returncode == 0 else ""


def _sink_index_to_name():
    """{sink index -> node.name} so we can tell which sink a stream sits on."""
    out = {}
    r = sh(PACTL, "list", "short", "sinks")
    if r.returncode != 0:
        return out
    for line in r.stdout.splitlines():
        p = line.split("\t")
        if len(p) >= 2:
            out[p[0].strip()] = p[1].strip()
    return out


def list_sink_inputs():
    """Parse `pactl list sink-inputs` into dicts:
       {id, sink_index, binary, appname, node_name, corked, volume}.
    A FAILED pactl RAISES so reconcile keeps the current assignment rather than
    reading a hiccup as 'no streams' and tearing everything down."""
    r = sh(PACTL, "list", "sink-inputs")
    if r.returncode != 0:
        raise RuntimeError("pactl list sink-inputs failed (rc=%s)" % r.returncode)
    items, cur, in_props = [], None, False
    for raw in r.stdout.splitlines():
        head = raw.rstrip()
        m = re.match(r"^Sink Input #(\d+)", head)
        if m:
            if cur:
                items.append(cur)
            cur = {"id": m.group(1), "sink_index": "", "binary": "",
                   "appname": "", "node_name": "", "corked": False,
                   "volume": None}
            in_props = False
            continue
        if cur is None:
            continue
        m = re.match(r"^\tSink:\s*(\d+)", head)
        if m:
            cur["sink_index"] = m.group(1)
            in_props = False
            continue
        m = re.match(r"^\tCorked:\s*(\w+)", head)
        if m:
            cur["corked"] = (m.group(1) == "yes")
            in_props = False
            continue
        if head.startswith("\tVolume:"):
            mm = re.search(r"(\d+)%", head)
            if mm:
                cur["volume"] = int(mm.group(1))
            in_props = False
            continue
        if head.startswith("\tProperties:"):
            in_props = True
            continue
        if re.match(r"^\t[A-Z]", head):
            in_props = False
        if in_props:
            m = re.match(r'^\t\t([\w.\-]+) = "(.*)"$', head)
            if m:
                k, v = m.group(1), m.group(2)
                if k == "application.process.binary":
                    cur["binary"] = v
                elif k == "application.name":
                    cur["appname"] = v
                elif k == "node.name":
                    cur["node_name"] = v
    if cur:
        items.append(cur)
    return items


def app_key(si):
    """Stable per-app grouping key (mirrors the bar's per-app gauges). This is the
    key the reconcile trims/publishes under: binary-first and lowercased so it's
    stable across runs, but for the shared Electron/Chromium launcher we fall back
    to the app/node name so two distinct Electron apps don't collide on one trim.
    Per-user Discord bridge streams (PerUserAudioSinks: discordpeer.<id>.out)
    key on their node.name FIRST — their owning binary is pipewire-pulse, which
    would collapse every participant onto one key. Mirrored in the awk resolver
    inside audio-streamfx (tools.nix)."""
    nn = (si.get("node_name") or "").lower()
    if nn.startswith("discordpeer."):
        return nn
    b = (si.get("binary") or "").lower()
    if b in ("", "electron", "chromium"):
        return (si.get("appname") or si.get("node_name") or "app").lower()
    return b


# ------------------------------------------------------------------- gain readout
# slot node.name -> MEASURED applied gain (percent, 100 = unity). Maintained by
# output_gain_loop; read by reconcile when it builds the published rows.
_slot_gain = {}
_slot_gain_db = {}           # slot -> measured gain in dB (for the arc)
# Auto-calibrated display range (dB) for the UI arcs: expands instantly to
# include any observed gain, relaxes slowly (0.05 dB/s) so stale extremes fade.
_rng = {"lo": None, "hi": None}
_slot_gain_lock = threading.Lock()


# Persistent per-slot readers, a PAIR per active slot. CRITICAL: we do NOT
# re-open a parec per measurement — repeatedly opening/closing a capture on a
# filter-chain sink's monitor forces the graph to reconfigure and produces
# xruns/crackle. Each pair maintains an EMA of:
#   pre:  the slot sink's monitor       = the app's signal BEFORE the leveler
#   post: --monitor-stream on the slot's '<slot>.out' playback bridge
#         = the signal AFTER the leveler+limiter (pre user trim — verified:
#           the stream monitor taps the raw stream data, not post-volume)
# so applied gain = post − pre, the plugin's REAL behaviour. The old approach
# (reconstruct target − pre-RMS) was fiction: RMS dBFS ≠ K-weighted LUFS, so
# the arc railed at the +12 dB clamp while the plugin was actually attenuating.
_slot_db = {}                # slot -> pre-filter EMA dBFS (None when silent)
_slot_db_out = {}            # slot -> post-filter EMA dBFS (None when silent)
_slot_readers = {}           # slot -> stop Event


def _ema_reader(cmd, store, key, stop):
    """Feed store[key] with a gated RMS EMA of a raw float32 mono capture."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception:
        return
    block = int(48000 * 4 * 0.2)          # 0.2 s blocks
    ema = None
    try:
        while not stop.is_set():
            buf = p.stdout.read(block)
            if not buf:
                break
            a = array.array("f")
            a.frombytes(buf[:len(buf) // 4 * 4])
            if not len(a):
                continue
            s = 0.0
            for v in a:
                s += v * v
            rms = math.sqrt(s / len(a))
            # Gate at -60 dBFS to match the leveler plugin's "level of silence"
            # (it freezes its gain there): quiet passages must not skew the EMA.
            if rms <= 1e-3:
                store[key] = None
            else:
                db = 20.0 * math.log10(rms)
                ema = db if ema is None else (0.7 * ema + 0.3 * db)
                store[key] = ema
    finally:
        try:
            p.kill()
        except Exception:
            pass
        store.pop(key, None)


def _monitor_reader(slot, stop):
    _ema_reader([PAREC, "-d", slot + ".monitor", "--format=float32le",
                 "--channels=1", "--rate=48000", "--raw"],
                _slot_db, slot, stop)


def _out_reader(slot, out_id, stop):
    _ema_reader([PAREC, "--monitor-stream=%s" % out_id, "--format=float32le",
                 "--channels=1", "--rate=48000", "--raw"],
                _slot_db_out, slot, stop)


# ------------------------------------------------------------------- trims
_trims = {}


def _load_trims():
    global _trims
    try:
        with open(TRIMS_FILE) as f:
            _trims = {str(k): int(v) for k, v in json.load(f).items()}
    except Exception:
        _trims = {}


def _save_trims():
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = TRIMS_FILE + ".tmp.%d" % os.getpid()
        with open(tmp, "w") as f:
            json.dump(_trims, f)
        os.replace(tmp, TRIMS_FILE)
    except Exception:
        pass


# ------------------------------------------------------------------- ducking
# Speech detector + duck state. One persistent parec --monitor-stream reader
# per live voice stream (same no-churn reasoning as the slot gain readers —
# open/close churn on captures causes xruns): a 50 ms RMS block above
# threshold_db marks speech, `active` drops after hold_ms with no speech.
# Engage/release call reconcile() directly — the subscribe loop's 0.2 s
# coalesce would add audible lag to the dip.
_duck_cfg = load_duck_config()        # refreshed at the top of every reconcile
_duck = {"active": False, "deadline": 0.0, "timer": None,
         # Separate freshness window for the OWN-SPEECH trigger: while hot,
         # dips deepen to mic_duck_db (see _duck_eff_db) — far-end-triggered
         # dips keep the polite duck_db/adaptive depth.
         "mic_deadline": 0.0}
_duck_lock = threading.Lock()
_duck_readers = {}                    # voice sink-input id -> stop Event
_duck_saved = {}                      # raw-ducked sink-input id -> pre-duck vol %
_duck_raw_state = {"applied": False}  # duck state the last raw pass applied
# Duck targets, rebuilt by every reconcile pass (under _recon_lock):
#   chains: filter-chain sink node.names (applvl.N / strmfx.P) hosting
#           non-priority streams — ducked via their in-graph duck-gain stage
#   raw:    unmanaged sink-input id -> (base %, dipped %) — volume fallback
_duck_fast = {"chains": set(), "voice_chains": set(), "raw": {}}
_chain_ids = {}                       # chain node.name -> pipewire node id
# Adaptive dip state: per-chain dip depth (dB), sized from live loudness by
# _duck_adaptive_update (static duck_db when adaptive is off / unmeasured).
DUCK_MAX_DB = 30.0
_duck_chain_dip = {}                  # chain -> current dip depth (dB)
_duck_chain_trim = {}                 # chain -> bridge trim % (heard-level calc)
_duck_voice_level = {"db": None}      # last measured heard voice loudness


def _trim_db(pct):
    """A bridge sink-input volume % as dB (pulse cubic: amp = (pct/100)^3)."""
    return 60.0 * math.log10(max(1, pct) / 100.0)


def _duck_mic_hot():
    """True while the own-speech trigger engaged/extended the current duck."""
    return _duck["mic_deadline"] > time.monotonic()


def _duck_eff_db():
    """Effective dip depth: the deeper of the far-end level and (while the
    user is the one speaking) the mic level."""
    db = _duck_cfg["duck_db"]
    if _duck_mic_hot():
        db = max(db, _duck_cfg["mic_duck_db"])
    return db


def _duck_eff_factor():
    """Pulse-% (cubic) multiplier for the effective dip depth."""
    return 10.0 ** (-_duck_eff_db() / 60.0)


def _dip(pct):
    """An effective-depth dip of a pulse volume %, on pulse's cubic scale."""
    return max(1, int(round(pct * _duck_eff_factor())))


def _resolve_chain_ids(names):
    """node.name -> pw node id for the duck-capable chain sinks, via one
    pw-dump. Chains are static (declared in pipewire.nix) so ids are cached
    for the daemon's lifetime; a failed set-param (PipeWire restarted => new
    ids) evicts the entry so the next call re-resolves."""
    missing = [n for n in names if n not in _chain_ids]
    if not missing:
        return
    r = sh(PW_DUMP, timeout=10)
    if r.returncode != 0:
        return
    try:
        for obj in json.loads(r.stdout):
            props = ((obj.get("info") or {}).get("props")) or {}
            nn = props.get("node.name")
            if nn in missing:
                _chain_ids[nn] = obj["id"]
    except Exception:
        pass


def _duck_chain_gain(name, f):
    """Linear gain for a chain at ramp position f, from its own dip depth.
    While the own-speech trigger is hot the mic depth FLOORS the adaptive
    per-chain dip (never shrinks it). Clamped to <= 1.0 — ducking only
    ever attenuates, never boosts."""
    if f <= 0:
        return 1.0
    dip = max(0.0, _duck_chain_dip.get(name, _duck_cfg["duck_db"]))
    if _duck_mic_hot():
        dip = max(dip, _duck_cfg["mic_duck_db"])
    return min(1.0, 10.0 ** (-(dip * f) / 20.0))


def _duck_adaptive_update():
    """Adaptive dip sizing (runs from output_gain_loop's 1 s tick): while
    FULLY dipped, re-size each ducked chain's dip so its HEARD loudness
    (post-chain measurement + bridge trim) sits margin_db below the QUIETEST
    priority source's heard loudness. The pre-duck level is recovered by
    de-embedding the dip we applied — feed-forward, not a feedback loop.
    Dips clamp to [0, DUCK_MAX_DB]: audio already quieter than the voice is
    LEFT ALONE (never raised), and slew-limiting (±4 dB/tick) keeps music
    dynamics from pumping the dip. Mid-ramp the measurement EMAs lag the
    gain we just set, so adaptation waits for the steady state."""
    if not (_duck_any_trigger() and _duck_cfg["adaptive"]):
        return
    # Heard loudness of the quietest priority source; held through gaps.
    vdbs = []
    for c in _duck_fast.get("voice_chains", set()):
        db = _slot_db_out.get(c)
        if db is not None:
            vdbs.append(db + _trim_db(_duck_chain_trim.get(c, 100)))
    if vdbs:
        _duck_voice_level["db"] = min(vdbs)
    vdb = _duck_voice_level["db"]
    if vdb is None:
        return
    if _duck_ramp["f"] != 1.0 or _duck_ramp["target"] != 1.0:
        return
    changed = False
    for c in list(_duck_fast["chains"]):
        out_db = _slot_db_out.get(c)
        if out_db is None:
            continue
        cur = max(0.0, _duck_chain_dip.get(c, _duck_cfg["duck_db"]))
        heard = out_db + _trim_db(_duck_chain_trim.get(c, 100))
        pre = heard + cur              # de-embed our own dip (f == 1 here)
        target = min(DUCK_MAX_DB,
                     max(0.0, pre - (vdb - _duck_cfg["margin_db"])))
        nxt = cur + max(-4.0, min(4.0, target - cur))
        if abs(nxt - cur) > 0.25:
            _duck_chain_dip[c] = nxt
            changed = True
    if changed:
        _duck_apply_f(1.0)


def _duck_set_chain_gain(name, gain):
    """Drive the chain's duck mixer stage — the same in-graph Props mechanism
    as the rnnoise dry/wet bypass. This is a SEPARATE multiply after the
    leveler+limiter; no user-owned volume moves."""
    sid = _chain_ids.get(name)
    if sid is None:
        _resolve_chain_ids({name})
        sid = _chain_ids.get(name)
        if sid is None:
            return
    r = sh(PW_CLI, "set-param", str(sid), "Props",
           '{ params = [ "duck_l:Gain 1" %.4f "duck_r:Gain 1" %.4f ] }'
           % (gain, gain))
    # pw-cli exits 0 even when the id is gone ("no global N any more" goes
    # to the output instead) — a PipeWire restart silently orphaned every
    # cached id this way (2026-10-04). Treat error TEXT as failure too.
    if r.returncode != 0 or "error" in (r.stdout + r.stderr).lower():
        _chain_ids.pop(name, None)   # stale id — PipeWire restarted


def _duck_sync_chains(new):
    """Reconcile the duck-target chain set: chains that left (app went away,
    stream became priority, slot freed) get their gain reset to unity; chains
    that joined mid-duck are brought to the current ramp position so a stream
    appearing mid-speech doesn't play loud until the next edge."""
    removed = _duck_fast["chains"] - new
    added = new - _duck_fast["chains"]
    _duck_fast["chains"] = new
    f = _duck_ramp["f"]
    for name in removed:
        _duck_chain_dip.pop(name, None)
        _duck_set_chain_gain(name, 1.0)
    if f > 0:
        for name in added:
            _duck_set_chain_gain(name, _duck_chain_gain(name, f))


def _is_voice_stream(si):
    """A stream whose audio TRIGGERS ducking (and must never be ducked):
    the voice app's own playback, or a per-user discordpeer.* bridge."""
    nn = (si.get("node_name") or "").lower()
    if nn.startswith("discordpeer."):
        return True
    return app_key(si) in _duck_cfg["voice_apps"]


# Ramped transitions. A hard volume step on every speech edge reads as
# flicker — especially the restore in each inter-word gap. Instead a single
# worker slides a duck fraction f (0 = restored, 1 = fully dipped) toward its
# target: fast on attack so the dip still lands with the voice, slow on
# release so gaps between sentences don't pump the music, and a resumed voice
# mid-release just turns the slide around from wherever it is (no snap).
# vol(f) = base * factor^f — linear-in-dB, which is what sounds even.
# Attack is a FAST slide (~80 ms at fine 20 ms steps): the dip must land
# within the first syllable — at the original 120 ms the duck audibly
# STARTED after speech began (2026-10-05, own-speech trigger), while the
# 50 ms/2-step version landed in time but read as a jarring cut (same day).
# 80 ms in four steps is the tuned middle: still inside the syllable,
# audibly a slide. Release stays the slow, coarse-stepped glide.
DUCK_ATTACK_S = 0.08
DUCK_ATTACK_TICK = 0.02
DUCK_RELEASE_S = 0.5
DUCK_RAMP_TICK = 0.08
_duck_ramp = {"f": 0.0, "target": 0.0}
_duck_ramp_cv = threading.Condition()


def _duck_any_trigger():
    """The two duck triggers are INDEPENDENT toggles: `enabled` = far-end
    voice (the priority-app stream readers), `mic_trigger` = the user's own
    speech. The duck machinery runs if either is on; there is no priority
    concept on the mic side — own speech just ducks everything."""
    return _duck_cfg["enabled"] or _duck_cfg["mic_trigger"]


def _duck_engaged():
    """True while ducking has ANY hold on the graph (fully dipped or
    mid-ramp) — gates the raw-stream fallback and the published state."""
    return _duck_any_trigger() and (
        _duck["active"] or _duck_ramp["f"] > 0 or _duck_ramp["target"] > 0)


def _duck_vol(pct):
    """pct dipped by the CURRENT ramp position (f=1 ≡ _dip(pct))."""
    f = _duck_ramp["f"]
    if f <= 0:
        return pct
    return max(1, int(round(pct * (_duck_eff_factor() ** f))))


def _duck_set_target(t):
    with _duck_ramp_cv:
        _duck_ramp["target"] = t
        _duck_ramp_cv.notify()


def _duck_apply_f(f):
    """Apply ramp position f to the cached targets — no graph re-listing, so
    a tick costs a few ms. Chains get their duck-gain stage set (linear dB
    interpolation; the user's volumes never move); unmanaged raw streams
    still dip their own sink-input volume (nothing else to set there).
    Endpoint passes nudge a follow-up reconcile to mop up anything the cache
    missed (streams that appeared mid-speech)."""
    try:
        with _recon_lock:
            for name in list(_duck_fast["chains"]):
                _duck_set_chain_gain(name, _duck_chain_gain(name, f))
            fac = _duck_eff_factor() ** f
            for sid, (base, _dipv) in _duck_fast["raw"].items():
                if f > 0:
                    _duck_saved.setdefault(sid, base)
                    sh(PACTL, "set-sink-input-volume", sid,
                       "%d%%" % max(1, int(round(base * fac))))
                elif _duck_saved.pop(sid, None) is not None:
                    sh(PACTL, "set-sink-input-volume", sid, "%d%%" % base)
            _duck_raw_state["applied"] = f > 0
    except Exception:
        pass
    if f in (0.0, 1.0):
        _wake.set()


def _duck_ramp_worker():
    while True:
        with _duck_ramp_cv:
            if _duck_ramp["f"] == _duck_ramp["target"]:
                _duck_ramp_cv.wait()
                continue
            tgt = _duck_ramp["target"]
            f = _duck_ramp["f"]
            if tgt > f:
                tick = DUCK_ATTACK_TICK
                f = min(tgt, f + tick / DUCK_ATTACK_S)
            else:
                tick = DUCK_RAMP_TICK
                f = max(tgt, f - tick / DUCK_RELEASE_S)
            _duck_ramp["f"] = f
        _duck_apply_f(f)
        if _duck_ramp["f"] != _duck_ramp["target"]:
            with _duck_ramp_cv:
                _duck_ramp_cv.wait(tick)


def _duck_voice_heard(src="stream"):
    engage = False
    deepen = False
    with _duck_lock:
        if not _duck_any_trigger():
            return
        hold = (_duck_cfg["mic_hold_ms"] if src == "mic"
                else _duck_cfg["hold_ms"]) / 1000.0
        now = time.monotonic()
        if src == "mic":
            # cold→hot while already dipped: the ramp is parked (no ticks),
            # so the deeper mic depth needs an explicit re-apply.
            deepen = _duck["active"] and not _duck_mic_hot()
            _duck["mic_deadline"] = now + hold
        # max(): the shorter mic hold must never CLIP a longer far-end hold
        # already in flight — deadlines only ever extend.
        _duck["deadline"] = max(_duck["deadline"], now + hold)
        if not _duck["active"]:
            _duck["active"] = True
            engage = True
        if _duck["timer"] is None:
            # Arm with THIS trigger's hold — arming with the far-end hold
            # made a mic-only duck release at 900 ms regardless of the
            # shorter mic deadline (the re-arming tick only fires then).
            t = threading.Timer(hold, _duck_tick)
            t.daemon = True
            _duck["timer"] = t
            t.start()
    if engage:
        _duck_set_target(1.0)
    elif deepen:
        _duck_apply_f(_duck_ramp["f"])


def _duck_tick():
    # Single re-arming release timer: readers only push the deadline forward
    # (cheap), instead of spawning a Timer thread per 50 ms speech block.
    with _duck_lock:
        remain = _duck["deadline"] - time.monotonic()
        if remain > 0.05 and _duck_any_trigger():
            t = threading.Timer(remain, _duck_tick)
            t.daemon = True
            _duck["timer"] = t
            t.start()
            return
        _duck["timer"] = None
        _duck["active"] = False
    _duck_set_target(0.0)


# ------------------------------------------------------------- muffle gate
# Someone ELSE talking in a caller's room reads as speech to the plain RMS
# gate: it ducked whatever was playing and stayed audible as chatter. Direct
# on-mic speech carries consonant/sibilant energy well above 2 kHz; room-
# muffled speech is low-passed and does not. Each hot 50 ms block's HIGH-BAND
# SHARE (first-difference RMS over full RMS, in dB — a one-sample diff is a
# 6 dB/oct high-pass, no FFT needed) classifies it: above muffle_hf_db it is
# direct speech. Direct evidence stays fresh for muffle_direct_ms so vowel-
# only blocks mid-sentence still count as speech. Hot blocks with NO fresh
# direct evidence are muffled-only: they do not trigger the duck, and once
# they sustain for muffle_engage_ms the VOICE chains' duck-gain stage (idle
# for voice chains otherwise — ducking never targets them) dips them by
# muffle_gate_db. Any direct block reopens the gate at once — close is slow,
# open is fast, so a real onset loses at most one detection block. Both
# voices share one mixed stream, so overlap passes through untouched: only
# ISOLATED muffled talk is gated. Chain-hosted voice streams only; unmanaged
# voice streams still get the trigger filtering.
_muffle = {"direct_ts": 0.0, "noise_since": None, "deadline": 0.0,
           "gate": False, "timer": None}
_muffle_lock = threading.Lock()
_muffle_ramp = {"f": 0.0, "target": 0.0}   # 0 = open (unity), 1 = fully dipped
_muffle_ramp_cv = threading.Condition()
MUFFLE_CLOSE_S = 0.35
MUFFLE_OPEN_S = 0.06
MUFFLE_TICK = 0.02


def _muffle_direct_fresh(now=None):
    return ((now if now is not None else time.monotonic())
            - _muffle["direct_ts"] <= _duck_cfg["muffle_direct_ms"] / 1000.0)


def _muffle_gain(f):
    if f <= 0:
        return 1.0
    return 10.0 ** (-(_duck_cfg["muffle_gate_db"] * f) / 20.0)


def _muffle_set_target(t):
    with _muffle_ramp_cv:
        _muffle_ramp["target"] = t
        _muffle_ramp_cv.notify()


def _muffle_apply_f(f):
    try:
        with _recon_lock:
            g = _muffle_gain(f)
            for name in list(_duck_fast["voice_chains"]):
                _duck_set_chain_gain(name, g)
    except Exception:
        pass


def _muffle_ramp_worker():
    while True:
        with _muffle_ramp_cv:
            if _muffle_ramp["f"] == _muffle_ramp["target"]:
                _muffle_ramp_cv.wait()
                continue
            tgt = _muffle_ramp["target"]
            f = _muffle_ramp["f"]
            if tgt > f:
                f = min(tgt, f + MUFFLE_TICK / MUFFLE_CLOSE_S)
            else:
                f = max(tgt, f - MUFFLE_TICK / MUFFLE_OPEN_S)
            _muffle_ramp["f"] = f
        _muffle_apply_f(f)
        if _muffle_ramp["f"] != _muffle_ramp["target"]:
            with _muffle_ramp_cv:
                _muffle_ramp_cv.wait(MUFFLE_TICK)


def _set_voice_chains(new):
    """Voice-chain set changes flow through here so the muffle gate's gain
    follows the streams: chains that left reset to unity (they may become
    duck targets this same pass), chains that joined mid-gate pick up the
    current dip."""
    old = _duck_fast["voice_chains"]
    _duck_fast["voice_chains"] = new
    f = _muffle_ramp["f"]
    for name in old - new:
        _duck_set_chain_gain(name, 1.0)
    if f > 0:
        for name in new - old:
            _duck_set_chain_gain(name, _muffle_gain(f))


def _muffle_cfg_check():
    """Mode left "on" with the gate still dipped (config change mid-gate) —
    reopen. The state flags clear via the release timer."""
    if _duck_cfg["muffle_mode"] != "on" and (
            _muffle_ramp["f"] > 0 or _muffle_ramp["target"] > 0):
        _muffle_set_target(0.0)


def _muffle_tick():
    # Re-arming release timer, same shape as _duck_tick: muffled blocks only
    # push the deadline forward.
    with _muffle_lock:
        remain = _muffle["deadline"] - time.monotonic()
        if remain > 0.05 and _duck_cfg["muffle_mode"] != "off":
            t = threading.Timer(remain, _muffle_tick)
            t.daemon = True
            _muffle["timer"] = t
            t.start()
            return
        _muffle["timer"] = None
        opened = _muffle["gate"]
        _muffle["gate"] = False
        _muffle["noise_since"] = None
    if opened:
        _muffle_set_target(0.0)
        print("muffle: background talk ended — gate open", flush=True)


def _muffle_block(direct, ratio_db):
    """One HOT block's classification → muffle state. Returns True when the
    block counts as speech (direct, or direct evidence still fresh) and may
    trigger the duck."""
    mode = _duck_cfg["muffle_mode"]
    now = time.monotonic()
    began = closed = opened = False
    with _muffle_lock:
        if direct:
            _muffle["direct_ts"] = now
            _muffle["noise_since"] = None
            if _muffle["gate"]:
                _muffle["gate"] = False
                opened = True
            trigger = True
        elif _muffle_direct_fresh(now):
            trigger = True       # vowel tail of direct speech, not background
        else:
            # Muffled-only activity. A gap past the release deadline restarts
            # the engage clock — a lone blip minutes later must not close the
            # gate instantly off a stale noise_since.
            if _muffle["noise_since"] is None or now > _muffle["deadline"]:
                _muffle["noise_since"] = now
                began = True
            _muffle["deadline"] = now + _duck_cfg["muffle_release_ms"] / 1000.0
            if (not _muffle["gate"] and now - _muffle["noise_since"]
                    >= _duck_cfg["muffle_engage_ms"] / 1000.0):
                _muffle["gate"] = True
                closed = True
                if _muffle["timer"] is None:
                    t = threading.Timer(
                        _duck_cfg["muffle_release_ms"] / 1000.0, _muffle_tick)
                    t.daemon = True
                    _muffle["timer"] = t
                    t.start()
            trigger = False
    if mode == "on":
        if opened:
            _muffle_set_target(0.0)
        elif closed:
            _muffle_set_target(1.0)
    if began:
        print("muffle: muffled-only talk (hf %.1f dB)" % ratio_db, flush=True)
    if closed:
        print("muffle%s: gate closed (-%.0f dB on voice chains)"
              % ("" if mode == "on" else "[log]",
                 _duck_cfg["muffle_gate_db"]), flush=True)
    if opened:
        print("muffle: direct speech (hf %.1f dB) — gate open" % ratio_db,
              flush=True)
    return trigger


def _duck_reader(sid, stop):
    """RMS speech gate on one voice stream's own audio. --monitor-stream taps
    the raw stream data (pre-volume), so user volume settings don't move the
    detection point; it also works while the stream sits on a per-user
    discord_user_* null sink."""
    try:
        p = subprocess.Popen(
            [PAREC, "--monitor-stream=%s" % sid, "--format=float32le",
             "--channels=1", "--rate=48000", "--raw",
             # parec's default record latency buffers ~hundreds of ms before
             # the first byte reaches us — that alone makes the dip trail the
             # voice. 30 ms keeps the detector essentially realtime.
             "--latency-msec=30"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception:
        return
    block = int(48000 * 4 * 0.05)        # 50 ms blocks: fast attack
    prev = 0.0                           # last sample, diff across block edges
    try:
        while not stop.is_set():
            buf = p.stdout.read(block)
            if not buf:
                break
            a = array.array("f")
            a.frombytes(buf[:len(buf) // 4 * 4])
            if not len(a):
                continue
            mode = _duck_cfg["muffle_mode"]
            s = 0.0
            if mode == "off":
                for v in a:
                    s += v * v
            else:
                sd = 0.0
                for v in a:
                    s += v * v
                    d = v - prev
                    sd += d * d
                    prev = v
            if math.sqrt(s / len(a)) > 10.0 ** (_duck_cfg["threshold_db"] / 20.0):
                if mode == "off":
                    _duck_voice_heard()
                else:
                    # high-band share: first-difference energy over full
                    # energy — 10·log10 because both are already squared sums
                    ratio = 10.0 * math.log10(sd / s) if sd > 0 else -99.0
                    speech = _muffle_block(
                        ratio > _duck_cfg["muffle_hf_db"], ratio)
                    if speech or mode == "log":
                        _duck_voice_heard()
    finally:
        try:
            p.kill()
        except Exception:
            pass


def _duck_mic_reader(stop):
    """RMS speech gate on the USER'S OWN voice, read from rnnoise_source —
    post-AEC + post-RNNoise, so played music is already cancelled/denoised
    out of the signal before detection (raw mic audio would re-trigger on
    the very music being ducked and pump). Shares _duck_voice_heard with
    the stream readers: either trigger extends the same hold. The daemon's
    cgroup (audio-balance.service) keeps this capture out of the mic-users
    listing via its is_balance gate, same as the loudness readers."""
    try:
        p = subprocess.Popen(
            [PAREC, "-d", "rnnoise_source", "--format=float32le",
             "--channels=1", "--rate=48000", "--raw",
             # Tighter than the stream readers' 30 ms: the dip must land
             # within the user's first syllable, and this path ALSO pays
             # the AEC+RNNoise chain latency before the voice reaches us.
             "--latency-msec=10"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except Exception:
        p = None
    try:
        if p is not None:
            # 20 ms RMS blocks (vs the stream readers' 50): worst-case
            # detection lag ~30 ms after the onset clears the chain.
            block = int(48000 * 4 * 0.02)
            # Onset debounce: a NEW dip needs 3 consecutive hot blocks
            # (60 ms sustained). Impulsive transients that survive RNNoise
            # (chair creaks, knocks) are over in a block or two; speech
            # onsets sustain well past 60 ms. While the mic trigger is
            # already hot, a single block extends the hold — no added lag
            # mid-speech.
            hot = 0
            while not stop.is_set():
                buf = p.stdout.read(block)
                if not buf:
                    break
                a = array.array("f")
                a.frombytes(buf[:len(buf) // 4 * 4])
                if not len(a):
                    continue
                s = 0.0
                for v in a:
                    s += v * v
                if math.sqrt(s / len(a)) > 10.0 ** (
                        _duck_cfg["mic_threshold_db"] / 20.0):
                    hot += 1
                    if hot >= 3 or _duck_mic_hot():
                        _duck_voice_heard("mic")
                else:
                    hot = 0
    finally:
        if p is not None:
            try:
                p.kill()
            except Exception:
                pass
        # Unlike the per-stream readers (whose sink-input vanishing removes
        # them), rnnoise_source is static — if parec dies while the reader is
        # still wanted (PipeWire restart), deregister so the next reconcile
        # respawns it.
        if _duck_readers.get(MIC_READER_KEY) is stop:
            _duck_readers.pop(MIC_READER_KEY, None)


MIC_READER_KEY = "mic"    # sentinel key in _duck_readers (real keys are ids)

# Gate for the mic trigger: is a REAL app listening to the mic right now?
# "A voice stream exists" is useless as a call signal on this desktop — the
# voice assistant, clip tool and other plumbing keep streams alive constantly.
# audio-mic-inuse (the red bar indicator's own gate) is the authoritative
# answer: audio-mic-users' mic-source allowlist + cgroup gates exclude every
# always-on system tap (wake-word recorder, replay buffer, mix-sync wrappers,
# shell meters, this daemon's own readers) and the inuse wrapper drops the
# pavucontrol-style meters on top. The result is cached and re-checked only
# when source-output membership changes (dirty-flagged from the subscribe
# thread) — not on every reconcile.
_mic_users_state = {"dirty": True, "val": False}


def _mic_in_use():
    if _mic_users_state["dirty"]:
        _mic_users_state["dirty"] = False
        try:
            r = sh(MIC_INUSE, timeout=10)
            _mic_users_state["val"] = (
                r.returncode == 0 and r.stdout.strip() == "yes")
        except Exception:
            _mic_users_state["val"] = False
    return _mic_users_state["val"]


def _duck_manage_readers(streams):
    """One detector per live (uncorked) voice stream while `enabled`. Plus,
    when mic_trigger is on (independently of `enabled`), ONE detector on the
    user's own mic — but only while a REAL app is capturing the mic (in a
    call / recording): otherwise nobody hears the mic, and talking over
    music in the room shouldn't duck it. See _mic_in_use for why "a voice
    stream exists" is not that signal."""
    want = set()
    if _duck_cfg["enabled"]:
        want = {si["id"] for si in streams
                if _is_voice_stream(si) and not si.get("corked", False)}
    if _duck_cfg["mic_trigger"] and _mic_in_use():
        if MIC_READER_KEY not in _duck_readers:
            stop = threading.Event()
            _duck_readers[MIC_READER_KEY] = stop
            threading.Thread(target=_duck_mic_reader, args=(stop,),
                             daemon=True).start()
        want = want | {MIC_READER_KEY}
    for sid in want - set(_duck_readers):
        stop = threading.Event()
        _duck_readers[sid] = stop
        threading.Thread(target=_duck_reader, args=(sid, stop),
                         daemon=True).start()
    for sid in set(_duck_readers) - want:
        _duck_readers.pop(sid).set()


def _duck_raw(streams, sink_name, bridge_ids, active):
    """Dip/restore the RAW sink-input volume of streams no bridge covers
    (balancing off, or pool overflow). bridge_ids are dipped at their slot/fx
    .out bridge instead. Pre-duck volumes are remembered in-memory and only
    restored while still at the value we set — a volume the user changed
    mid-duck wins over the restore (and is never raised above what we saved)."""
    _duck_fast["raw"].clear()
    live = set()
    for si in streams:
        sid = si["id"]
        live.add(sid)
        nn = si.get("node_name", "")
        if _SKIP_STREAM_RE.match(nn) or nn.endswith(".out"):
            continue
        if sink_name.get(si.get("sink_index", ""), "").startswith("discord_user_"):
            continue             # per-user originals: voice, and app-pinned
        if _is_voice_stream(si):
            continue
        vol = si.get("volume")
        saved = _duck_saved.get(sid)
        if sid in bridge_ids or not active:
            # restore (stream got a bridge mid-duck, or duck fully released).
            # Anywhere inside the duck range counts (the ramp may have been
            # interrupted); a volume the user pushed ABOVE the saved base is
            # theirs and is left alone.
            restored = None
            if saved is not None:
                _duck_saved.pop(sid, None)
                if vol is not None and _dip(saved) - 1 <= vol <= saved + 1:
                    sh(PACTL, "set-sink-input-volume", sid, "%d%%" % saved)
                    restored = saved
            if sid not in bridge_ids:
                base = restored if restored is not None else vol
                if base is not None:
                    _duck_fast["raw"][sid] = (base, _dip(base))
            continue
        if saved is None and vol is not None:
            # appeared mid-duck: dip to the CURRENT ramp position, not the
            # endpoint, or it would jump ahead of everything else.
            saved = vol
            _duck_saved[sid] = vol
            sh(PACTL, "set-sink-input-volume", sid, "%d%%" % _duck_vol(vol))
        if saved is not None:
            _duck_fast["raw"][sid] = (saved, _dip(saved))
    # forget saved volumes for streams that vanished while ducked
    for sid in list(_duck_saved):
        if sid not in live:
            _duck_saved.pop(sid)


# ------------------------------------------------------------------- state file
def _atomic_write(obj):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = STATE_FILE + ".tmp.%d" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, STATE_FILE)


# ------------------------------------------------------------------- reconcile
# slot node.name -> app key currently assigned to it (in-memory, authoritative)
_assign = {}
# stream id -> the real output device ("home") it was headed to before we pulled
# it onto a leveler slot. Each slot's .out bridge is routed back to its stream's
# home, so balancing keeps a stream on the device it was meant for (per-device)
# rather than funnelling every levelled stream onto the default. Streams whose
# home is the default (the usual case) are left to follow the default as before.
_home = {}
_recon_lock = threading.Lock()
_last_published = None
_publish_lock = threading.Lock()
# Rows published by the output reconcile. Input (per-mic capture-volume)
# balancing was removed 2026-08-28 — it fought the user's mic levels; the
# "input" key stays as [] for frontend compat.
_output_rows = []
_input_rows = []


def _move(stream_id, sink_name):
    sh(PACTL, "move-sink-input", stream_id, sink_name)


def _is_real_output(name):
    """A sink audio actually comes OUT of — a physical/aggregate device — not one
    of our own routing/plumbing sinks (leveler slots, fx chains, per-user or cast
    null-sinks, the MIX aggregate, or any '.out' bridge). Used to learn a balanced
    stream's home device (see _home)."""
    if not name:
        return False
    if name in SLOT_SINKS or name in FX_SINKS:
        return False
    if name.endswith(".out"):
        return False
    return not name.startswith(
        ("applvl.", "strmfx.", "castaudio_", "discord_user_", "combined_"))


# ---- post-leveler per-app offset -------------------------------------------
# The user's per-app volume must live AFTER the leveler, or the leveler just
# normalises it away. Each slot's playback bridge (applvl.<n>.out) is a real
# sink-input on the hardware sink whose volume is applied POST-filter — so that
# is where the gauge trims. 100 % = at the balanced target; the leveler (upstream)
# can't undo it. audio-balance-setvol sets it live; the daemon resets it to 100 %
# whenever a slot is handed to a different stream (so a new stream never inherits
# the previous one's trim), and reads it back to publish for the gauge.
_slot_stream = {}       # slot -> stream id it was last (re)set for
_fx_streams = {}        # fx sink -> "id,id,..." signature of the streams pinned to it


def _applvl_out_ids():
    """slot/fx-sink node.name -> the sink-input id of its '<name>.out' bridge."""
    out = {}
    try:
        for si in list_sink_inputs():
            nn = si.get("node_name", "")
            if nn.endswith(".out") and (nn[:-4] in SLOT_SINKS or nn[:-4] in FX_SINKS):
                out[nn[:-4]] = si["id"]
    except Exception:
        pass
    return out


def _get_sinkinput_vol(sid):
    r = sh(PACTL, "list", "sink-inputs")
    if r.returncode != 0:
        return None
    cur = None
    for line in r.stdout.splitlines():
        m = re.match(r"^Sink Input #(\d+)", line)
        if m:
            cur = m.group(1)
        elif cur == str(sid) and "Volume:" in line and "%" in line:
            mm = re.search(r"(\d+)%", line)
            if mm:
                return int(mm.group(1))
    return None


def _set_out_vol(slot, pct, out_ids=None):
    ids = out_ids if out_ids is not None else _applvl_out_ids()
    sid = ids.get(slot)
    if sid is not None:
        sh(PACTL, "set-sink-input-volume", str(sid), "%d%%" % pct)


# --------------------------------------------------------- AVRCP remote volume
# A bluetooth A2DP SOURCE (a phone playing into this machine) reports its
# volume buttons over AVRCP: bluez emits PropertiesChanged on the device's
# MediaTransport1 Volume (0-127). The phone ALSO scales its outgoing PCM, but
# the leveler normalises that away — so the buttons are routed to the stream's
# post-leveler trim (the same applvl.<n>.out volume the UI gauge drives, which
# reconcile persists per app key). Off-slot streams get their sink-input volume
# set directly instead (no leveler to fight there).
#
# The sync is TWO-WAY: Volume is writable, so when the trim changes PC-side
# (gauge drag, restored trim on reconnect) reconcile pushes it back to the
# transport and the phone's own volume display tracks the PC. The echo of our
# own write (bluez re-emits it) is dropped by value in the watcher.
_avrcp_state = {}        # mac -> {"vol": 0-127 last seen, "path": transport path}
_avrcp_lock = threading.Lock()


def _avrcp_pct(vol):
    """AVRCP 0-127 -> pactl percent, linear: the phone's displayed volume and
    the PC gauge agree (0=0, 100=100). pactl's percent scale is itself
    perceptually spaced (cubed amplitude), matching how volume steps are meant
    to feel — no curve correction on top."""
    return max(0, min(100, int(round(vol * 100.0 / 127.0))))


def _avrcp_raw(pct):
    """Inverse of _avrcp_pct."""
    return max(0, min(127, int(round(pct * 127.0 / 100.0))))


def _avrcp_mac_of(node_name):
    """bluez_input.<MAC>.<sep> -> the underscored MAC part, or ''."""
    m = re.match(r"bluez_input\.([0-9A-Fa-f_]+)\.\d+$", node_name or "")
    return m.group(1) if m else ""


def _avrcp_known_pct(mac):
    """Phone's current volume as a trim pct, or None if no transport seen."""
    with _avrcp_lock:
        st = _avrcp_state.get(mac)
        return _avrcp_pct(st["vol"]) if st and st["vol"] is not None else None


def _avrcp_sync_to_phone(mac, pct):
    """Push the PC-side trim to the phone's volume display. Writes only when
    the phone meaningfully disagrees (±1 raw step absorbs the pct<->127
    rounding). A short grace window after any phone-originated change wins
    conflicts for the phone: a reconcile pass that read the trim BEFORE a
    button press landed must not shove the stale value back."""
    with _avrcp_lock:
        st = _avrcp_state.get(mac)
        if not st or not st.get("path") or st["vol"] is None:
            return
        if time.time() - st["phone_ts"] < 2.0:
            return
        desired = _avrcp_raw(pct)
        if abs(desired - st["vol"]) <= 1:
            return
        st["vol"] = desired     # pre-mark so the echo is recognised
        path = st["path"]
    sh(BUSCTL, "set-property", "org.bluez", path,
       "org.bluez.MediaTransport1", "Volume", "q", str(desired))


def _avrcp_boost_pct(vol):
    """The phone scales its own PCM by ~vol/127 before transmitting (iOS does
    this even with absolute volume active). Cancel it exactly: a sink-input
    volume whose CUBIC amplitude is 127/vol makes the audio entering the slot
    full-scale-equivalent, so the trim is the ONLY effective volume and the
    gauge's percent means the same loudness as any other app's. Capped at
    200% (+18 dB) — below ~12% phone volume the bottom end just stays quiet
    rather than boosting noise into audibility."""
    if vol <= 0:
        return 100
    return min(200, int(round(100.0 * (127.0 / vol) ** (1.0 / 3.0))))


def _avrcp_apply(mac, vol):
    pct = _avrcp_pct(vol)
    prefix = "bluez_input." + mac
    try:
        streams = list_sink_inputs()
    except Exception:
        return
    sink_name = _sink_index_to_name()
    for si in streams:
        if not si.get("node_name", "").startswith(prefix):
            continue
        cur = sink_name.get(si.get("sink_index", ""), "")
        if cur in SLOT_SINKS or cur in FX_SINKS:
            # Undo the phone-side scaling on the stream, carry the volume on
            # the trim (post-leveler, same place every app's gauge acts).
            sh(PACTL, "set-sink-input-volume", str(si["id"]),
               "%d%%" % _avrcp_boost_pct(vol))
            _set_out_vol(cur, pct)
            _wake.set()      # reconcile re-reads + persists the trim
        else:
            # Off-slot there is no trim stage: fold both into the stream
            # volume (inverse boost × desired cubic pct = pct·(127/vol)^⅓).
            eff = 0 if vol <= 0 else min(
                200, int(round(pct * (127.0 / vol) ** (1.0 / 3.0))))
            sh(PACTL, "set-sink-input-volume", str(si["id"]), "%d%%" % eff)
        return


def _avrcp_seed():
    """Populate _avrcp_state from transports that already exist (daemon
    started while the phone was connected) — without this, PC->phone sync is
    dead until the first button press creates the state entry."""
    r = sh(BUSCTL, "tree", "org.bluez", "--list")
    if r.returncode != 0:
        return
    for line in r.stdout.splitlines():
        m = re.match(r"\s*(/org/bluez/[^/]+/dev_([0-9A-Fa-f_]+)/sep\d+/fd\d+)\s*$",
                     line)
        if not m:
            continue
        path, mac = m.group(1), m.group(2)
        rv = sh(BUSCTL, "get-property", "org.bluez", path,
                "org.bluez.MediaTransport1", "Volume")
        mv = re.match(r"q (\d+)", rv.stdout.strip()) if rv.returncode == 0 else None
        if mv:
            with _avrcp_lock:
                _avrcp_state[mac] = {"vol": int(mv.group(1)), "path": path,
                                     "phone_ts": 0.0}


def _avrcp_watch():
    """Follow MediaTransport1 Volume changes via dbus-monitor (event-driven,
    the bluetooth counterpart of `pactl subscribe`). Respawns on exit."""
    match = ("type='signal',interface='org.freedesktop.DBus.Properties',"
             "member='PropertiesChanged',arg0='org.bluez.MediaTransport1'")
    while True:
        try:
            _avrcp_seed()
        except Exception:
            pass
        try:
            p = subprocess.Popen([DBUS_MONITOR, "--system", match],
                                 stdout=subprocess.PIPE, text=True)
        except Exception:
            time.sleep(5.0)
            continue
        mac = ""
        path = ""
        pending = False
        for line in p.stdout:
            m = re.search(r"path=(/org/bluez/[^/]+/dev_([0-9A-Fa-f_]+)/\S*)", line)
            if m:
                path, mac = m.group(1), m.group(2)
                pending = False
                continue
            if '"Volume"' in line:
                pending = True
                continue
            if pending:
                pending = False
                mv = re.search(r"uint16 (\d+)", line)
                if mv and mac:
                    vol = int(mv.group(1))
                    with _avrcp_lock:
                        st = _avrcp_state.setdefault(
                            mac, {"vol": None, "path": path, "phone_ts": 0.0})
                        st["path"] = path
                        # our own write-back echoes with the same value
                        echo = st["vol"] is not None and abs(st["vol"] - vol) <= 1
                        st["vol"] = vol
                        if not echo:
                            st["phone_ts"] = time.time()
                    if not echo:
                        try:
                            _avrcp_apply(mac, vol)
                        except Exception:
                            pass
        p.wait()
        with _avrcp_lock:
            _avrcp_state.clear()   # transports gone (bluez/monitor restart)
        time.sleep(2.0)


def reconcile():
    with _recon_lock:
        _reconcile_locked()


# Set by the pactl-subscribe thread on real graph events (vs the 1s ticker):
# the standalone loop-breaker below runs only on these, so idle ticks stay
# subprocess-free while any change that could form a loop triggers a check.
_evt_wake = {"flag": False}
# The daemon main-loop wake event (module-level so the duck fast path can
# nudge a follow-up reconcile without running one inline).
_wake = threading.Event()


def _break_feedback_loops():
    """Evict any per-user BRIDGE stream sitting on a discord_user_* sink —
    per-user monitor feeding a per-user sink is a closed feedback loop that
    screamed at full scale (2026-09-10). Standalone so it protects even while
    balancing AND fx are OFF (the main reconcile bails early then). Gated on
    the cheap sink listing: no discord_user sinks, no further work."""
    r = sh(PACTL, "list", "short", "sinks")
    if r.returncode != 0 or "discord_user_" not in r.stdout:
        return
    sink_name = _sink_index_to_name()
    dflt = default_sink()
    if not dflt or dflt.startswith("discord_user_"):
        # The default itself is a per-user sink (the incident trigger) —
        # evict to a real hardware sink instead.
        dflt = ""
        for line in r.stdout.splitlines():
            p = line.split("\t")
            if len(p) >= 2 and re.match(r"^(alsa|bluez)_output\.", p[1]):
                dflt = p[1]
                break
    if not dflt:
        return
    try:
        streams = list_sink_inputs()
    except Exception:
        return
    for si in streams:
        cur = sink_name.get(si.get("sink_index", ""), "")
        nn = si.get("node_name", "")
        if cur.startswith("discord_user_") and (
                nn.startswith("discordpeer.") or nn.startswith("output.loopback")):
            _move(si["id"], dflt)


def _disable_cleanup():
    """One-shot teardown when balancing goes off AND no fx rules remain: evict
    anything still parked on a slot or fx sink back to the default sink and
    reset the post-filter trims so nothing is left attenuated. Only worth its
    pactl cost when we actually held state — the caller gates on that so
    idle-disabled ticks never reach here."""
    dflt = default_sink()
    if dflt.startswith("discord_user_"):
        dflt = ""   # never evict onto a per-user sink (feedback loop)
    sink_name = _sink_index_to_name()
    out_ids = _applvl_out_ids()
    try:
        streams = list_sink_inputs()
    except Exception:
        streams = []
    for si in streams:
        cur = sink_name.get(si.get("sink_index", ""), "")
        if (cur in SLOT_SINKS or cur in FX_SINKS) and dflt \
                and not _SKIP_STREAM_RE.match(si.get("node_name", "")):
            _move(si["id"], dflt)
    for slot in list(SLOT_SINKS) + sorted(FX_SINKS):
        _set_out_vol(slot, 100, out_ids)
    _assign.clear()
    _slot_stream.clear()
    _fx_streams.clear()
    _home.clear()
    _duck_sync_chains(set())
    _set_output_rows([])


def _reconcile_locked():
    # Everything off is the DEFAULT — bail before ANY pactl/subprocess call so
    # the ticker (and every subscribe wake) costs nothing on an idle desktop.
    # Only when we still hold in-memory state (i.e. we just transitioned to
    # all-off) do we pay for the one-shot cleanup, which then empties that
    # state so subsequent disabled ticks return here immediately. Re-enabling
    # is unaffected: the config-change signal / subscribe thread re-triggers
    # reconcile and this guard falls through.
    global _duck_cfg
    _duck_cfg = load_duck_config()
    _muffle_cfg_check()
    enabled = load_config()["output_enabled"]
    fx_rules = load_fx_rules()
    if not enabled and not fx_rules:
        if _assign or _slot_stream or _fx_streams:
            _disable_cleanup()
        evt = _evt_wake["flag"]
        if evt:
            _evt_wake["flag"] = False
            _break_feedback_loops()
        # Ducking still works with balancing AND fx off — but only pay for a
        # stream listing on real graph events or a duck transition, so idle
        # ticks with ducking disabled stay subprocess-free as before.
        if (_duck_any_trigger() or _duck_readers or _duck_saved) and (
                evt or _duck_raw_state["applied"] != _duck_engaged()):
            try:
                streams = list_sink_inputs()
            except Exception:
                return
            _duck_manage_readers(streams)
            _set_voice_chains(set())
            _duck_sync_chains(set())        # nothing parked on chains here
            engaged = _duck_engaged()
            _duck_raw(streams, _sink_index_to_name(), set(), engaged)
            _duck_raw_state["applied"] = engaged
        return

    try:
        streams = list_sink_inputs()
    except Exception:
        return  # transient pactl failure — keep current assignment
    sink_name = _sink_index_to_name()
    dflt = default_sink()
    # NEVER evict/re-home anything onto a per-user sink masquerading as the
    # default (the 2026-09-10 feedback incident) — better to leave streams
    # where they are than to feed the loop.
    if dflt.startswith("discord_user_"):
        dflt = ""

    streams_by_id = {}          # sink-input id -> stream (real app streams only)
    for si in streams:
        cur_sink = sink_name.get(si.get("sink_index", ""), "")
        nn = si.get("node_name", "")
        # LOOP BREAKER (2026-09-10 incident): a per-user BRIDGE stream
        # (discordpeer.*.out / a peruser loopback) sitting ON a discord_user_*
        # sink is a closed feedback path — per-user monitor feeding a per-user
        # sink screamed at full scale. Evict it to the real default sink
        # IMMEDIATELY, before any other consideration.
        if cur_sink.startswith("discord_user_") and (
                nn.startswith("discordpeer.") or nn.startswith("output.loopback")):
            if dflt and not dflt.startswith("discord_user_"):
                _move(si["id"], dflt)
            continue
        if _SKIP_STREAM_RE.match(nn):
            continue
        # Streams the PerUserAudioSinks Vesktop plugin routed onto a per-user
        # null-sink (discord_user_<id>) are pinned there BY the app — moving
        # them would collapse the per-user split. The user's balanceable/
        # filterable stream is that sink's discordpeer.<id>.out bridge, which
        # sits on a real output and flows through here normally.
        if cur_sink.startswith("discord_user_"):
            continue
        # A stream the per-player cast button routed onto a cast null-sink
        # (castaudio_<device>, created by castAudio) is pinned there to cast
        # JUST that player — exactly like the per-user case above. Leaving it
        # be is what makes per-stream casting work: otherwise the slot
        # reconcile below yanks it straight back onto its applvl.<n> leveler,
        # emptying the cast sink (silence on the device). castAudio tears the
        # sink down when the cast ends, so the stream rejoins the pool on its
        # own — no explicit un-pin needed here.
        if cur_sink.startswith("castaudio_"):
            continue
        streams_by_id[si["id"]] = si

    with _slot_gain_lock:
        gains = dict(_slot_gain)
        gains_db = dict(_slot_gain_db)
    out_ids = _applvl_out_ids()
    # Current sink of EVERY sink-input (incl. the .out bridges) + the set of live
    # sink names — used to route each slot's .out bridge to its stream's home
    # device (per-device balancing) without churn.
    live_sinks = set(sink_name.values())
    si_cur_sink = {si["id"]: sink_name.get(si.get("sink_index", ""), "")
                   for si in streams}
    trims_dirty = False

    # Ducking: detectors follow the voice streams; capture the duck state once
    # so this pass applies ONE consistent state everywhere (the release timer
    # can flip it mid-pass).
    _duck_manage_readers(streams)
    duck_on = _duck_engaged()
    duck_chains = set()       # chains hosting non-priority streams this pass
    voice_chains = set()      # chains hosting priority streams (level refs)

    # ---- FX pinning (independent of balancing) -----------------------------
    # A rule pins EVERY stream of the app onto the preset's sink; several
    # streams (or even apps) sharing a preset simply mix before the filter.
    # Unlike balance slots (one stream per leveler for correctness), that
    # mixing is exactly what you want for e.g. a multi-stream Discord call.
    fx_by_sink = {}             # fx sink -> [stream ids, ascending]
    for sid in sorted(streams_by_id, key=int):
        preset = fx_rules.get(app_key(streams_by_id[sid]))
        if preset:
            fx_by_sink.setdefault(FX_PRESETS[preset], []).append(sid)
    fx_ids = set()
    for fsink, sids in fx_by_sink.items():
        for sid in sids:
            fx_ids.add(sid)
            cur = sink_name.get(streams_by_id[sid].get("sink_index", ""), "")
            if cur != fsink:
                _move(sid, fsink)
    # Evict streams squatting on an fx sink they're not pinned to (rule
    # removed, or WirePlumber's stream-target restore respawning a stream
    # straight onto the sink). Balance re-homes its own assignees below.
    if dflt:
        for sid, si in streams_by_id.items():
            if sid in fx_ids:
                continue
            if sink_name.get(si.get("sink_index", ""), "") in FX_SINKS:
                _move(sid, dflt)

    fx_rows = []
    for fsink in sorted(fx_by_sink):
        sids = fx_by_sink[fsink]
        key = app_key(streams_by_id[sids[0]])
        sig = ",".join(sids)
        # Priority (voice) streams TRIGGER ducking and are never duck
        # targets; every other chain ducks via its in-graph duck-gain stage,
        # so the bridge volume below stays purely the user's trim.
        hosts_voice = any(_is_voice_stream(streams_by_id[s]) for s in sids)
        if not hosts_voice:
            duck_chains.add(fsink)
        # New pinning on this sink? Apply the app's saved post-filter trim —
        # the SAME per-app store as the balance trims, so the user's gauge
        # setting carries over when fx toggles on/off or slots reshuffle.
        if _fx_streams.get(fsink) != sig:
            _fx_streams[fsink] = sig
            offset = _trims.get(key, 100)
            _set_out_vol(fsink, offset, out_ids)
        else:
            offset = _get_sinkinput_vol(out_ids.get(fsink)) if fsink in out_ids else 100
            if offset is None:
                offset = 100
            if offset != _trims.get(key, 100):
                if offset == 100:
                    _trims.pop(key, None)
                else:
                    _trims[key] = offset
                trims_dirty = True
        if hosts_voice:
            voice_chains.add(fsink)
        _duck_chain_trim[fsink] = offset
        fx_rows.append({"key": key, "ids": [int(s) for s in sids],
                        "gain": gains.get(fsink, 100),
                        "gain_db": round(gains_db.get(fsink, 0.0), 1),
                        "offset": offset, "slot": fsink,
                        "fx": fsink.split(".", 1)[1],
                        "prio": 1 if hosts_voice else 0,
                        # this chain's CURRENT dip depth (adaptive), for the
                        # gauge's hatched span — a global dB no longer fits
                        "dip": 0 if hosts_voice else round(
                            max(0.0, _duck_chain_dip.get(fsink, _duck_cfg["duck_db"])), 1)})
    # Freed fx sinks: reset the bridge trim so the next pinning starts clean.
    for fsink in list(_fx_streams):
        if fsink not in fx_by_sink:
            _fx_streams.pop(fsink)
            _set_out_vol(fsink, 100, out_ids)

    # ---- Balancing ---------------------------------------------------------
    if not enabled:
        # Balance is off while fx stays active: one-shot eviction of anything
        # still parked on a slot (enabled→disabled transition), then publish
        # the fx rows only.
        if _assign or _slot_stream:
            for sid, si in streams_by_id.items():
                cur = sink_name.get(si.get("sink_index", ""), "")
                if cur in SLOT_SINKS and dflt:
                    _move(sid, dflt)
            for slot in SLOT_SINKS:
                _set_out_vol(slot, 100, out_ids)
            _assign.clear()
            _slot_stream.clear()
            _home.clear()
        if trims_dirty:
            _save_trims()
        _set_voice_chains(voice_chains)
        _duck_sync_chains(duck_chains)
        _duck_raw(streams, sink_name, fx_ids, duck_on)
        _duck_raw_state["applied"] = duck_on
        _set_output_rows(fx_rows)
        return

    # One slot per STREAM (sink-input), NOT per app. Two streams of the same app
    # — e.g. two browser profiles playing different things — are genuinely
    # different sources and must be levelled independently; grouping them by
    # binary would collapse both onto one leveler and balance nothing. Keyed by
    # the sink-input id, which is stable for the life of the stream. (Two tabs in
    # ONE browser profile still share a single sink-input — that's the browser
    # emitting one mixed stream, which we can't split.) Fx-pinned streams are
    # not the balancer's to place.
    bal_streams = {sid: si for sid, si in streams_by_id.items() if sid not in fx_ids}

    # Drop assignments whose stream has gone away (or got pinned to fx).
    for slot in list(_assign.keys()):
        if _assign[slot] not in bal_streams:
            del _assign[slot]
    assigned_ids = set(_assign.values())

    # Assign new streams to free slots, LIVE streams first. A corked (paused/
    # idle) stream is silent, so it must never hold a slot a playing stream
    # needs: with the pool full of squatters, live audio ended up on the real
    # sink UNLEVELED while paused streams kept their levelers (a long-idle
    # soundboard mpv + a paused Firefox stream pinned two of the four slots,
    # 2026-10-03 — music then flapped between leveled and raw as streams came
    # and went). So when the pool is full, a live stream STEALS the slot of a
    # corked one: moving the silent victim back to the default sink is
    # pop-free, and it gets a slot again when it resumes (change event) or a
    # slot frees up. Trims are per-app and restored on re-park, so nothing is
    # lost in the shuffle.
    free = [s for s in SLOT_SINKS if s not in _assign]
    for sid in sorted(bal_streams, key=lambda s: (bal_streams[s].get("corked", False), int(s))):
        if sid in assigned_ids:
            continue
        if not free and not bal_streams[sid].get("corked", False):
            victim = next((sl for sl, vid in _assign.items()
                           if bal_streams.get(vid, {}).get("corked", False)), None)
            if victim is not None:
                assigned_ids.discard(_assign.pop(victim))
                free.append(victim)
        if not free:
            break            # pool full of live streams — extras are evicted to the default sink below
        slot = free.pop(0)
        _assign[slot] = sid
        assigned_ids.add(sid)

    # Evict any stream squatting on a slot it is NOT assigned to. WirePlumber's
    # stream-target restore remembers our own past moves (keyed by app name —
    # and by shared media.role, which crosses APPS) and respawns streams
    # DIRECTLY onto applvl sinks, so a new stream can land on another app's
    # slot and share its leveler, limiter and .out bridge volume (Overwatch's
    # gauge moved YouTube Music, 2026-08-29). Slot occupancy is authoritative:
    # a stream assigned elsewhere is re-homed by the loop below (cur != slot);
    # an UNASSIGNED one (pool full) goes back to the default sink here —
    # unbalanced on the real output, exactly what "no slot" is meant to be.
    if dflt:
        for sid, si in bal_streams.items():
            if sid in assigned_ids:
                continue
            cur = sink_name.get(si.get("sink_index", ""), "")
            if cur in SLOT_SINKS:
                _move(sid, dflt)

    # Ensure each assigned stream sits on its slot; publish its per-stream gain.
    rows = []
    # Forget cached gains for slots no longer assigned/pinned (so a freed slot
    # doesn't keep a stale value if it's reused).
    for slot in list(_slot_gain.keys()):
        if slot not in _assign and slot not in _fx_streams:
            with _slot_gain_lock:
                _slot_gain.pop(slot, None)
                _slot_gain_db.pop(slot, None)
    # Trims are persisted per APP key but slots are per STREAM: with two
    # streams of one app the rows would fight over the single _trims entry
    # every pass (row 1 writes its offset, row 2 deletes it). First row wins.
    seen_trim_keys = set()
    for slot, sid in _assign.items():
        si = streams_by_id.get(sid)
        if not si:
            continue
        cur = sink_name.get(si.get("sink_index", ""), "")
        if cur != slot:
            # Learn the stream's home device the moment before we pull it onto the
            # slot — but only a REAL output, never our own plumbing sinks. A stream
            # already sitting on its slot keeps whatever home we last recorded.
            if _is_real_output(cur):
                _home[sid] = cur
            _move(si["id"], slot)
        # Route this slot's levelled-output bridge to the stream's home device.
        # home == default (the usual case) or unknown -> send it to the default,
        # which is exactly the old global behaviour and keeps following default /
        # MIX (combined_out) changes. A specific NON-default home pins the bridge
        # there, so a stream balanced while playing on a second output stays on
        # THAT device instead of being dumped on the default — per-device balance.
        if dflt:
            _out_id = out_ids.get(slot)
            _h = _home.get(sid)
            _want = _h if (_h and _h != dflt and _h in live_sinks) else dflt
            if _out_id and si_cur_sink.get(_out_id, "") != _want:
                _move(_out_id, _want)
        key = app_key(si)
        is_voice = _is_voice_stream(si)
        if not is_voice:
            duck_chains.add(slot)   # ducked via the chain's duck-gain stage
        # New stream on this slot? Apply the APP's saved post-leveler trim (so
        # trims survive restarts / reassignment) rather than inheriting the
        # previous stream's offset. Unknown apps start matched (100%).
        # Bluetooth A2DP-source streams are volume-synced with the sending
        # device (AVRCP): the DEVICE's current volume is the trim, never a
        # saved default — a phone at 0 must not come back at 100.
        bt_mac = _avrcp_mac_of(si.get("node_name", ""))
        if _slot_stream.get(slot) != sid:
            _slot_stream[slot] = sid
            offset = _trims.get(key, 100)
            if bt_mac:
                known = _avrcp_known_pct(bt_mac)
                if known is not None:
                    offset = known
            _set_out_vol(slot, offset, out_ids)
        else:
            offset = _get_sinkinput_vol(out_ids.get(slot)) if slot in out_ids else 100
            if offset is None:
                offset = 100
            # The gauge drives this volume directly (audio-balance-setvol);
            # persist what we observe, per app. 100 = default, don't store.
            if key not in seen_trim_keys and offset != _trims.get(key, 100):
                if offset == 100:
                    _trims.pop(key, None)
                else:
                    _trims[key] = offset
                trims_dirty = True
        if is_voice:
            voice_chains.add(slot)
        _duck_chain_trim[slot] = offset
        seen_trim_keys.add(key)
        # Bluetooth A2DP-source stream: mirror the trim onto the phone's own
        # volume display (AVRCP absolute volume). No-op when they already agree.
        bt_mac = _avrcp_mac_of(si.get("node_name", ""))
        if bt_mac:
            _avrcp_sync_to_phone(bt_mac, offset)
        rows.append({"key": key, "ids": [int(sid)], "gain": gains.get(slot, 100),
                     "gain_db": round(gains_db.get(slot, 0.0), 1),
                     "offset": offset, "slot": slot,
                     "prio": 1 if is_voice else 0,
                     "dip": 0 if is_voice else round(
                         max(0.0, _duck_chain_dip.get(slot, _duck_cfg["duck_db"])), 1)})
    if trims_dirty:
        _save_trims()
    # Forget stream-tracking for freed slots.
    for slot in list(_slot_stream.keys()):
        if slot not in _assign:
            _slot_stream.pop(slot, None)
    # Forget home-device memory for streams no longer balanced.
    _assigned_sids = set(_assign.values())
    for sid in list(_home.keys()):
        if sid not in _assigned_sids:
            _home.pop(sid, None)
    _set_voice_chains(voice_chains)
    _duck_sync_chains(duck_chains)
    # Streams no chain covers (pool overflow) still dip their own volume.
    _duck_raw(streams, sink_name, set(_assign.values()) | fx_ids, duck_on)
    _duck_raw_state["applied"] = duck_on
    _set_output_rows(rows + fx_rows)


def output_gain_loop():
    """Keep a steady monitor reader per assigned slot; from each reader's EMA
    loudness reconstruct the applied gain for the arc. No per-iteration parec
    spawning (that churn caused xruns/crackle), so normal listening is untouched."""
    while True:
        cfg = load_config()
        active = set(_assign.keys()) if cfg["output_enabled"] else set()
        # fx sinks measure the same way (pre monitor vs .out bridge stream) and
        # are active whenever something is pinned, balancing on or off.
        active |= set(_fx_streams.keys())
        # start reader pairs for newly-active slots
        newly = active - set(_slot_readers)
        out_ids = _applvl_out_ids() if newly else {}
        for slot in newly:
            stop = threading.Event()
            _slot_readers[slot] = stop
            threading.Thread(target=_monitor_reader, args=(slot, stop),
                             daemon=True).start()
            if slot in out_ids:
                threading.Thread(target=_out_reader, args=(slot, out_ids[slot], stop),
                                 daemon=True).start()
        # stop readers for slots no longer active
        for slot in set(_slot_readers) - active:
            _slot_readers.pop(slot).set()
        # measured gain = post-filter loudness − pre-filter loudness
        changed = False
        cur = []
        for slot in active:
            db = _slot_db.get(slot)
            db_out = _slot_db_out.get(slot)
            if db is None or db_out is None:
                continue
            g_db = db_out - db
            g_db = max(OUTPUT_MIN_GAIN_DB, min(OUTPUT_MAX_AMP_DB, g_db))
            cur.append(g_db)
            g = int(round(100.0 * (10.0 ** (g_db / 20.0))))
            with _slot_gain_lock:
                _slot_gain_db[slot] = g_db
                if _slot_gain.get(slot) != g:
                    _slot_gain[slot] = g
                    changed = True
        # auto-calibrate the arc display range from observed gains
        rng_moved = False
        if cur:
            lo, hi = min(cur), max(cur)
            with _slot_gain_lock:
                old = (_rng["lo"], _rng["hi"])
                if _rng["lo"] is None:
                    _rng["lo"], _rng["hi"] = lo, hi
                else:
                    _rng["lo"] = min(lo, _rng["lo"] + 0.05)
                    _rng["hi"] = max(hi, _rng["hi"] - 0.05)
                rng_moved = (round(old[0] or 0, 1), round(old[1] or 0, 1)) != \
                            (round(_rng["lo"], 1), round(_rng["hi"], 1))
        if changed:
            reconcile()
        elif rng_moved:
            _publish()
        try:
            _duck_adaptive_update()
        except Exception:  # noqa: BLE001 — never kill the gain thread
            pass
        time.sleep(1.0)


def _set_output_rows(rows):
    global _output_rows
    _output_rows = rows
    _publish()


def _publish():
    global _last_published
    with _slot_gain_lock:
        lo, hi = _rng["lo"], _rng["hi"]
    if lo is None:
        rng = None
    else:
        # pad to a minimum 3 dB span so a lone / steady app sits mid-arc
        # instead of railing at an end of a zero-width range
        if hi - lo < 3.0:
            pad = (3.0 - (hi - lo)) / 2.0
            lo, hi = lo - pad, hi + pad
        rng = {"lo": round(lo, 1), "hi": round(hi, 1)}
    with _publish_lock:
        obj = {"output": _output_rows, "input": _input_rows, "range": rng,
               "duck": {"enabled": _duck_cfg["enabled"],
                        "active": _duck["active"],
                        "db": _duck_cfg["duck_db"],
                        "mic": _duck_cfg["mic_trigger"],
                        "muffle": _duck_cfg["muffle_mode"],
                        "muffle_gate": _muffle["gate"]}}
        if obj != _last_published:
            _last_published = obj
            _atomic_write(obj)


# ------------------------------------------------------------------- daemon
def cmd_daemon(_args):
    _load_trims()
    wake = _wake

    def sub():
        # `pactl subscribe` streams change events; sink-input events are the ones
        # that matter (app starts/stops/moves), plus server (default sink change).
        # The subscription DIES when pipewire-pulse restarts — respawn it, and
        # treat each respawn as a probable PipeWire restart: every cached chain
        # node id is suspect, so drop them for re-resolution (2026-10-04: stale
        # ids silently ate all duck set-params after a pipewire restart).
        while True:
            p = subprocess.Popen([PACTL, "subscribe"],
                                 stdout=subprocess.PIPE, text=True)
            for line in p.stdout:
                # Capture (source-output) MEMBERSHIP changes re-gate the mic
                # duck trigger — 'new'/'remove' only, so per-capture 'change'
                # chatter (volume moves on persistent taps) stays wake-free.
                if "source-output" in line:
                    if "'new'" in line or "'remove'" in line:
                        _mic_users_state["dirty"] = True
                        # evt too: the balancing-off early path only manages
                        # duck readers on real graph events.
                        _evt_wake["flag"] = True
                        wake.set()
                elif "sink-input" in line or "server" in line or "sink" in line:
                    _evt_wake["flag"] = True
                    wake.set()
            _chain_ids.clear()
            _evt_wake["flag"] = True
            _mic_users_state["dirty"] = True
            wake.set()
            time.sleep(2.0)

    threading.Thread(target=sub, daemon=True).start()

    def on_hup(*_a):
        wake.set()
    signal.signal(signal.SIGHUP, on_hup)
    signal.signal(signal.SIGTERM, lambda *a: os._exit(0))

    # OUTPUT gain arc: reconstruct applied gain from pre-filter monitor loudness.
    threading.Thread(target=output_gain_loop, daemon=True).start()
    # Phone volume buttons (AVRCP) -> the stream's post-leveler trim.
    threading.Thread(target=_avrcp_watch, daemon=True).start()
    # Duck ramp worker: slides volumes between base and dipped on duck edges.
    threading.Thread(target=_duck_ramp_worker, daemon=True).start()
    # Muffle gate ramp: slides the voice chains' gain on gate edges.
    threading.Thread(target=_muffle_ramp_worker, daemon=True).start()

    reconcile()   # first paint
    # Periodic light refresh keeps the published gain arc live while assigned
    # (the leveler gain drifts continuously); event-driven for assignment.
    def ticker():
        while True:
            time.sleep(1.0)
            wake.set()
    threading.Thread(target=ticker, daemon=True).start()

    while True:
        wake.wait()
        time.sleep(0.2)          # coalesce bursts
        wake.clear()
        try:
            reconcile()
        except Exception:
            pass


def main():
    import argparse
    ap = argparse.ArgumentParser(prog="audio-balance")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("daemon").set_defaults(func=cmd_daemon)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
