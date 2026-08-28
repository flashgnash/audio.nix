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

# OUTPUT arc reconstruction. The autogain plugin's applied-gain meter port is NOT
# exposed by PipeWire filter-chains, so we can't read it directly. Instead we
# measure each slot's PRE-filter input loudness (the sink monitor taps before the
# graph) and reconstruct the makeup gain the leveler applies to reach target —
# same target/limits as the filter (see pipewire.nix 99-app-balance). This drives
# the blue "adjustment" arc and confirms leveling is actually happening.
OUTPUT_TARGET_LUFS = -18.0   # must match the filter's "Desired loudness level"
OUTPUT_MAX_AMP_DB = 12.0     # must match the filter's "maximum amplification gain"
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

# Must match the pool size declared in flakes/audio/pipewire.nix (99-app-balance).
NSLOTS = int(os.environ.get("BALANCE_SLOTS", "4"))
SLOT_SINKS = ["applvl.%d" % i for i in range(NSLOTS)]

# Streams we must never try to balance: the balance sinks' own outputs, and the
# other virtual plumbing that shows up as sink-inputs.
_SKIP_STREAM_RE = re.compile(r"^(applvl\.|tailnet-|combined_)")


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
    """Stable per-app grouping key (mirrors the bar's per-app gauges)."""
    b = (si.get("binary") or "").lower()
    if b in ("", "electron", "chromium"):
        return (si.get("appname") or si.get("node_name") or "app").lower()
    return b


# ------------------------------------------------------------------- gain readout
# slot node.name -> reconstructed applied gain (percent, 100 = unity). Maintained
# by output_gain_loop (measures the slot's pre-filter monitor loudness); read by
# reconcile when it builds the published rows.
_slot_gain = {}
_slot_gain_db = {}           # slot -> reconstructed gain in dB (for the arc)
# Auto-calibrated display range (dB) for the UI arcs: expands instantly to
# include any observed gain, relaxes slowly (0.05 dB/s) so stale extremes fade.
_rng = {"lo": None, "hi": None}
_slot_gain_lock = threading.Lock()


# Persistent per-slot monitor readers. CRITICAL: we do NOT re-open a parec per
# measurement — repeatedly opening/closing a capture on a filter-chain sink's
# monitor forces the graph to reconfigure and produces xruns/crackle. Instead one
# steady capture per active slot maintains an EMA of that slot's PRE-filter input
# loudness (the monitor taps before the filter graph), from which the applied gain
# is reconstructed for the arc.
_slot_db = {}                # slot -> latest EMA dBFS (or None when silent)
_slot_readers = {}           # slot -> stop Event


def _monitor_reader(slot, stop):
    try:
        p = subprocess.Popen(
            [PAREC, "-d", slot + ".monitor", "--format=float32le",
             "--channels=1", "--rate=48000", "--raw"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
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
            # (it freezes its gain there): quiet passages must not drag the EMA
            # down, or the reconstructed gain rails at the +12 dB clamp.
            if rms <= 1e-3:
                _slot_db[slot] = None
            else:
                db = 20.0 * math.log10(rms)
                ema = db if ema is None else (0.7 * ema + 0.3 * db)
                _slot_db[slot] = ema
    finally:
        try:
            p.kill()
        except Exception:
            pass
        _slot_db.pop(slot, None)


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


def _applvl_out_ids():
    """slot node.name -> the sink-input id of its '<slot>.out' playback bridge."""
    out = {}
    try:
        for si in list_sink_inputs():
            nn = si.get("node_name", "")
            if nn.endswith(".out") and nn[:-4] in SLOT_SINKS:
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


def _reconcile_locked():
    global _last_published
    cfg = load_config()
    try:
        streams = list_sink_inputs()
    except Exception:
        return  # transient pactl failure — keep current assignment
    sink_name = _sink_index_to_name()
    dflt = default_sink()

    # One slot per STREAM (sink-input), NOT per app. Two streams of the same app
    # — e.g. two browser profiles playing different things — are genuinely
    # different sources and must be levelled independently; grouping them by
    # binary would collapse both onto one leveler and balance nothing. Keyed by
    # the sink-input id, which is stable for the life of the stream. (Two tabs in
    # ONE browser profile still share a single sink-input — that's the browser
    # emitting one mixed stream, which we can't split.)
    streams_by_id = {}          # sink-input id -> stream
    for si in streams:
        nn = si.get("node_name", "")
        if _SKIP_STREAM_RE.match(nn):
            continue
        streams_by_id[si["id"]] = si

    if not cfg["output_enabled"]:
        # Balancing off — evict anything still parked on a slot back to default,
        # and reset the post-leveler trims so nothing is left attenuated.
        out_ids = _applvl_out_ids()
        for si in streams:
            cur = sink_name.get(si.get("sink_index", ""), "")
            if cur in SLOT_SINKS and dflt and not _SKIP_STREAM_RE.match(si.get("node_name", "")):
                _move(si["id"], dflt)
        for slot in SLOT_SINKS:
            _set_out_vol(slot, 100, out_ids)
        _assign.clear()
        _slot_stream.clear()
        _set_output_rows([])
        return

    # Drop assignments whose stream has gone away.
    for slot in list(_assign.keys()):
        if _assign[slot] not in streams_by_id:
            del _assign[slot]
    assigned_ids = set(_assign.values())

    # Assign new streams to free slots.
    free = [s for s in SLOT_SINKS if s not in _assign]
    for sid in streams_by_id:
        if sid in assigned_ids:
            continue
        if not free:
            break            # pool full — extra streams stay unbalanced on the real sink
        slot = free.pop(0)
        _assign[slot] = sid
        assigned_ids.add(sid)

    # Ensure each assigned stream sits on its slot; publish its per-stream gain.
    rows = []
    with _slot_gain_lock:
        gains = dict(_slot_gain)
        gains_db = dict(_slot_gain_db)
    # Forget cached gains for slots no longer assigned (so a freed slot doesn't
    # keep a stale value if it's reused).
    for slot in list(_slot_gain.keys()):
        if slot not in _assign:
            with _slot_gain_lock:
                _slot_gain.pop(slot, None)
                _slot_gain_db.pop(slot, None)
    out_ids = _applvl_out_ids()
    for slot, sid in _assign.items():
        si = streams_by_id.get(sid)
        if not si:
            continue
        cur = sink_name.get(si.get("sink_index", ""), "")
        if cur != slot:
            _move(si["id"], slot)
        # New stream on this slot? Reset its post-leveler trim to matched (100%),
        # so it never inherits the previous stream's offset.
        if _slot_stream.get(slot) != sid:
            _slot_stream[slot] = sid
            _set_out_vol(slot, 100, out_ids)
            offset = 100
        else:
            offset = _get_sinkinput_vol(out_ids.get(slot)) if slot in out_ids else 100
            if offset is None:
                offset = 100
        key = (si.get("appname") or si.get("node_name") or si.get("binary") or "app")
        rows.append({"key": key, "ids": [int(sid)], "gain": gains.get(slot, 100),
                     "gain_db": round(gains_db.get(slot, 0.0), 1),
                     "offset": offset, "slot": slot})
    # Forget stream-tracking for freed slots.
    for slot in list(_slot_stream.keys()):
        if slot not in _assign:
            _slot_stream.pop(slot, None)
    _set_output_rows(rows)


def output_gain_loop():
    """Keep a steady monitor reader per assigned slot; from each reader's EMA
    loudness reconstruct the applied gain for the arc. No per-iteration parec
    spawning (that churn caused xruns/crackle), so normal listening is untouched."""
    while True:
        cfg = load_config()
        active = set(_assign.keys()) if cfg["output_enabled"] else set()
        # start readers for newly-active slots
        for slot in active - set(_slot_readers):
            stop = threading.Event()
            _slot_readers[slot] = stop
            threading.Thread(target=_monitor_reader, args=(slot, stop),
                             daemon=True).start()
        # stop readers for slots no longer active
        for slot in set(_slot_readers) - active:
            _slot_readers.pop(slot).set()
        # reconstruct gain from the readers' EMA loudness
        changed = False
        cur = []
        for slot in active:
            db = _slot_db.get(slot)
            if db is None:
                continue
            g_db = OUTPUT_TARGET_LUFS - db
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
    wake = threading.Event()

    def sub():
        # `pactl subscribe` streams change events; sink-input events are the ones
        # that matter (app starts/stops/moves), plus server (default sink change).
        p = subprocess.Popen([PACTL, "subscribe"], stdout=subprocess.PIPE, text=True)
        for line in p.stdout:
            if "sink-input" in line or "server" in line:
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
