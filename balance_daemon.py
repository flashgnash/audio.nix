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
PAREC = os.environ.get("PAREC", "parec")

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
# the other virtual plumbing that shows up as sink-inputs.
_SKIP_STREAM_RE = re.compile(r"^(applvl\.|strmfx\.|tailnet-|combined_)")


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
       {id, sink_index, binary, appname, node_name}.
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
                   "appname": "", "node_name": ""}
            in_props = False
            continue
        if cur is None:
            continue
        m = re.match(r"^\tSink:\s*(\d+)", head)
        if m:
            cur["sink_index"] = m.group(1)
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


def reconcile():
    with _recon_lock:
        _reconcile_locked()


# Set by the pactl-subscribe thread on real graph events (vs the 1s ticker):
# the standalone loop-breaker below runs only on these, so idle ticks stay
# subprocess-free while any change that could form a loop triggers a check.
_evt_wake = {"flag": False}


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
    _set_output_rows([])


def _reconcile_locked():
    # Everything off is the DEFAULT — bail before ANY pactl/subprocess call so
    # the ticker (and every subscribe wake) costs nothing on an idle desktop.
    # Only when we still hold in-memory state (i.e. we just transitioned to
    # all-off) do we pay for the one-shot cleanup, which then empties that
    # state so subsequent disabled ticks return here immediately. Re-enabling
    # is unaffected: the config-change signal / subscribe thread re-triggers
    # reconcile and this guard falls through.
    enabled = load_config()["output_enabled"]
    fx_rules = load_fx_rules()
    if not enabled and not fx_rules:
        if _assign or _slot_stream or _fx_streams:
            _disable_cleanup()
        if _evt_wake["flag"]:
            _evt_wake["flag"] = False
            _break_feedback_loops()
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
        streams_by_id[si["id"]] = si

    with _slot_gain_lock:
        gains = dict(_slot_gain)
        gains_db = dict(_slot_gain_db)
    out_ids = _applvl_out_ids()
    trims_dirty = False

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
        fx_rows.append({"key": key, "ids": [int(s) for s in sids],
                        "gain": gains.get(fsink, 100),
                        "gain_db": round(gains_db.get(fsink, 0.0), 1),
                        "offset": offset, "slot": fsink,
                        "fx": fsink.split(".", 1)[1]})
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
        if trims_dirty:
            _save_trims()
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

    # Assign new streams to free slots.
    free = [s for s in SLOT_SINKS if s not in _assign]
    for sid in bal_streams:
        if sid in assigned_ids:
            continue
        if not free:
            break            # pool full — extra streams are evicted to the default sink below
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
            _move(si["id"], slot)
        key = app_key(si)
        # New stream on this slot? Apply the APP's saved post-leveler trim (so
        # trims survive restarts / reassignment) rather than inheriting the
        # previous stream's offset. Unknown apps start matched (100%).
        if _slot_stream.get(slot) != sid:
            _slot_stream[slot] = sid
            offset = _trims.get(key, 100)
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
        seen_trim_keys.add(key)
        rows.append({"key": key, "ids": [int(sid)], "gain": gains.get(slot, 100),
                     "gain_db": round(gains_db.get(slot, 0.0), 1),
                     "offset": offset, "slot": slot})
    if trims_dirty:
        _save_trims()
    # Forget stream-tracking for freed slots.
    for slot in list(_slot_stream.keys()):
        if slot not in _assign:
            _slot_stream.pop(slot, None)
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
        obj = {"output": _output_rows, "input": _input_rows, "range": rng}
        if obj != _last_published:
            _last_published = obj
            _atomic_write(obj)


# ------------------------------------------------------------------- daemon
def cmd_daemon(_args):
    _load_trims()
    wake = threading.Event()

    def sub():
        # `pactl subscribe` streams change events; sink-input events are the ones
        # that matter (app starts/stops/moves), plus server (default sink change).
        p = subprocess.Popen([PACTL, "subscribe"], stdout=subprocess.PIPE, text=True)
        for line in p.stdout:
            if "sink-input" in line or "server" in line or "sink" in line:
                _evt_wake["flag"] = True
                wake.set()

    threading.Thread(target=sub, daemon=True).start()

    def on_hup(*_a):
        wake.set()
    signal.signal(signal.SIGHUP, on_hup)
    signal.signal(signal.SIGTERM, lambda *a: os._exit(0))

    # OUTPUT gain arc: reconstruct applied gain from pre-filter monitor loudness.
    threading.Thread(target=output_gain_loop, daemon=True).start()

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
