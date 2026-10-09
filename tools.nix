# Backend audio tools — extracted from the quickshell panel so any UI (or
# plain shell) can drive the PipeWire stack. Each tool is a bin named
# audio-<thing>; audioctl is a dispatcher over them.
{ pkgs }:
let
  audio-naming-awk = ''
    function _shorten_words(s,    parts, n, i, out) {
      n = split(s, parts, /[[:space:]]+/)
      if (n > 3) n = 3
      out = ""
      for (i = 1; i <= n; i++) out = (out == "") ? parts[i] : (out " " parts[i])
      return out
    }
    # Cap s at limit chars, breaking at the last word boundary that fits.
    # Used to keep bar labels from overflowing when no friendly label exists.
    function _truncate_chars(s, limit,    cut, i, c) {
      if (length(s) <= limit) return s
      cut = limit
      for (i = limit; i > 0; i--) {
        c = substr(s, i, 1)
        if (c == " " || c == "-" || c == "_") { cut = i - 1; break }
      }
      if (cut <= 0) cut = limit
      return substr(s, 1, cut)
    }
    function friendly_label(port, card, device,    eld_path, line, mname, n) {
      # NOTE: deliberately no "Built In" rule for analog-output-speaker /
      # analog-input-mic ports — USB headsets, DACs and external analog gear
      # all report those same port names, so the heuristic mislabelled half
      # the devices as "Built In". Fall back to the real description instead.
      if (port ~ /^hdmi-output-/) {
        if (card != "" && device != "") {
          eld_path = "/proc/asound/card" card "/eld#" device ".0"
          mname = ""
          while ((getline line < eld_path) > 0) {
            if (line ~ /^monitor_name/) {
              sub(/^monitor_name[\t ]+/, "", line)
              mname = line
              break
            }
          }
          close(eld_path)
          if (mname != "") return mname
        }
        n = port; sub(/^hdmi-output-/, "", n)
        return "HDMI " (n + 1)
      }
      return ""
    }
    function display_name(port, card, device, desc,    label) {
      label = friendly_label(port, card, device)
      if (label == "") return desc
      return label " (" _shorten_words(desc) ")"
    }
    # Bar-style short name: friendly label if there is one, otherwise the
    # raw description truncated to 8 chars at a word boundary (matches the
    # old `getDefaultSink | trim 8` behavior so bar layout stays stable).
    function short_name(port, card, device, desc,    label) {
      label = friendly_label(port, card, device)
      if (label != "") return label
      return _truncate_chars(desc, 8)
    }
    # ── Canonical internal-node filter ──────────────────────────────────
    # THE single authority on which node names are our own audio plumbing
    # and must never surface as a selectable device, mixer row or mic
    # user. Every lister calls this instead of keeping a private mask, so
    # a new internal node gets added HERE (plus the python twin the
    # audio-devices daemon keeps: _VIRT_SINK_RE/_VIRT_SRC_RE + entry
    # guards in hm-modules/phone-mic/audio_devices.py) and every
    # enumeration path agrees at once.
    #
    # Deliberately NOT matched here, because a bare name cannot decide:
    #  - tailnet-out-*: the route-PROXY sink is internal but shares the
    #    prefix with the user-facing phone-speaker sink; the discriminator
    #    is the tailnet_audio.route property (list-sinks keeps that
    #    property check alongside this filter).
    #  - soundboard / tailnet-route-recv: app-like playback streams that
    #    are deliberately visible in the app mixer (named so they read
    #    sensibly there).
    #  - gsr-*: only internal when cgroup+exe prove the real replay
    #    buffer recorder — audio-mic-users keeps its proof-based check
    #    (a name-only mask would let anything hide behind the name).
    function internal_node(name) {
      # mic filter stack (echo-cancel then rnnoise): the virtual Noise
      # Canceling Source and the capture streams of the stack —
      # capture.rnnoise_source is the AEC intake (it holds the interface
      # name), capture.rnnoise_source.filter the pinned rnnoise-chain capture;
      # both prefix-matched. Represented by the noise-cancel toggle.
      # NB: NO apostrophes in this awk library — it is embedded in
      # single-quoted shell strings and one unbalances the quoting.
      if (name == "rnnoise_source") return 1
      if (name ~ /^capture\.rnnoise_source/) return 1
      # echo-cancel stage internals: the cancelled output feeding the rnnoise
      # chain, and the reference tap on the default sink monitor.
      if (name == "aec_source") return 1
      if (name == "aec_ref") return 1
      # access-guard mic quarantine: the silent parking sink for ungated
      # capture streams (modules/access-guard). Its monitor surfaced as a
      # pickable "mic-quarantine" tile in the input panel (2026-10-08).
      if (name == "quarantine_mic") return 1
      if (name ~ /^quarantine_mic\./) return 1
      # mic-blend combiner (Combined Microphones) and its per-mic capture
      # streams (capture.combined_mics*, uniquified by PipeWire) — the
      # input MIX toggle is the representation.
      if (name == "combined_mics") return 1
      if (name ~ /^capture\.combined_mics/) return 1
      # output duplicator (module-combine-sink) and its per-slave
      # playback streams — the output MIX toggle / dup-sink mixer rows.
      if (name == "combined_out") return 1
      if (name ~ /^output\.combined_out/) return 1
      # per-app balance pool: applvl.<n> leveler sinks and applvl.<n>.out
      # bridge streams (see balance_daemon.py) — parked on, never picked.
      if (name ~ /^applvl\./) return 1
      # per-stream fx presets: strmfx.<preset> filter sinks and their .out
      # bridges (99-stream-fx / audio-streamfx) — pinned to, never picked.
      if (name ~ /^strmfx\./) return 1
      # PerUserAudioSinks (Vesktop): per-participant null-sinks — routing
      # plumbing, never a selectable output. Their discordpeer.<id>.out
      # bridge streams are deliberately NOT masked: they are the per-user
      # gauges in the app mixer.
      if (name ~ /^discord_user_/) return 1
      # mix-sync / cast-sync fixed-delay wrappers (delayed.<node>) plus
      # the pw-loopback instances behind them: sync.<mic>, castsync.<sink>
      # and bare pw-loopback fallback names — represented by the real
      # device they wrap.
      if (name ~ /^delayed\./) return 1
      if (name ~ /^sync\./ || name ~ /^castsync\./) return 1
      if (name ~ /^pw-loopback/) return 1
      # kernel snd_aloop card (guest-gaming plumbing): the input half
      # would pipe played audio into the mic mix, the output half must
      # never receive mirrored audio. Substring match — covers both the
      # alsa_input. and alsa_output. halves (Loopback Analog Stereo).
      if (name ~ /platform-snd_aloop/) return 1
      # chromecast plumbing: castaudio_<dev> (audio-cast null-sink) and
      # cast_<dev> (screen-mirror capture sink) — the cast UI / device
      # row is the representation.
      if (name ~ /^castaudio_/ || name ~ /^cast_/) return 1
      # tailnet-audio mic plumbing: donation null-sink (tailnet-mic-),
      # mic-consume receiver null-sink (tailnet-inmic-) and the consumed
      # remote-mic remap source (tailnet-rmic-, shown as its mesh row).
      # tailnet-out-* is NOT matched — see the header above.
      if (name ~ /^tailnet-mic-/ || name ~ /^tailnet-inmic-/ || name ~ /^tailnet-rmic-/) return 1
      # every sink grows a PipeWire monitor source (combined_out.monitor,
      # castaudio_*.monitor, ...) — captured internally by cast/tailnet/
      # balance readers, never a mic row.
      if (name ~ /\.monitor$/) return 1
      # our own meter/calibration capture streams: bar level meter,
      # per-mic VAD taps, mix-sync calibration recorders.
      if (name == "qs-mic-level" || name == "qs-vad" || name == "mix-sync-cal") return 1
      # venmic virtual mic that exists only while a Discord screen share
      # captures audio (QuickScreenShare) — never a device or mic user.
      if (name == "vencord-screen-share") return 1
      return 0
    }
  '';

  # The canonical filter as a bin, for sites that cannot embed the awk
  # library (python daemons, other nix modules like guest-gaming.nix).
  #   audio-internal-node <name>   → exit 0 if <name> is internal plumbing
  #   audio-internal-node          → filter stdin (one node name per line),
  #                                  printing only the NON-internal ones
  internal-node-sh = pkgs.writeShellScriptBin "audio-internal-node" ''
    if [ $# -gt 0 ]; then
      printf '%s\n' "$1" | ${pkgs.gawk}/bin/awk '
        ${audio-naming-awk}
        { exit internal_node($0) ? 0 : 1 }'
    else
      ${pkgs.gawk}/bin/awk '
        ${audio-naming-awk}
        !internal_node($0) { print }'
    fi
  '';

  # Connects a BT device by MAC and then sets it as the default sink or source
  bt-audio-connect-sh = pkgs.writeShellScriptBin "audio-bt-connect" ''
    mac="$1"
    kind="$2"   # "sink" or "source"
    bluetoothctl connect "$mac" >/dev/null 2>&1
    mac_under=$(echo "$mac" | tr ':' '_')
    device=""
    for i in $(seq 1 10); do
      if [ "$kind" = "sink" ]; then
        device=$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep "$mac_under" | head -1)
      else
        device=$(pactl list short sources 2>/dev/null | awk '{print $2}' | grep "$mac_under" | head -1)
      fi
      [ -n "$device" ] && break
      sleep 0.5
    done
    [ -n "$device" ] && pactl "set-default-$kind" "$device"
    echo "done"
  '';

  list-sinks-sh = pkgs.writeShellScriptBin "audio-list-sinks" ''
    default=$(pactl get-default-sink 2>/dev/null)
    pactl list sinks | awk -v def="$default" '
      ${audio-naming-awk}
      function emit(    bt, cur) {
        # Internal plumbing never gets a device row — the canonical
        # internal_node() mask decides (combined_out → the MIX toggle,
        # cast/tailnet null-sinks → their cast/mesh rows, delay wrappers →
        # the real sink they wrap, applvl pool, snd_aloop). The phone-
        # SPEAKER sink tailnet-out-<host> is NOT internal and DOES belong
        # here (a usable output = your phone).
        if (internal_node(name)) return
        # Local PROXY sinks for a REMOTE output are represented by their remote
        # device row; the NAME alone cannot tell a route proxy from the
        # user-facing phone-speaker sink (both tailnet-out-*), so this one
        # stays a property check: route proxies carry tailnet_audio.route.
        if (is_route) return
        bt  = (name ~ /^bluez_/) ? 1 : 0
        cur = (name == def) ? "1" : "0"
        printf "%s|%s|%s|%s\n", name, display_name(port, alsa_card, alsa_device, desc), cur, bt
      }
      /tailnet_audio\.route/ { is_route = 1 }
      /^Sink #/  { if (name != "") emit()
                   name = ""; desc = ""; port = ""; alsa_card = ""; alsa_device = ""; is_route = 0 }
      /^\tName:/        { name = $2 }
      /^\tDescription:/ { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/ { port = $3 }
      /alsa\.card = /   { match($0, /"[^"]*"/); alsa_card   = substr($0, RSTART+1, RLENGTH-2) }
      /alsa\.device = / { match($0, /"[^"]*"/); alsa_device = substr($0, RSTART+1, RLENGTH-2) }
      END { if (name != "") emit() }
    '
    # Unconnected but PAIRED BT audio sinks (Audio Sink UUID: 0000110b).
    # Only paired devices belong in the picker; `bluetoothctl devices` lists every
    # seen device, so filter with the piped `devices Paired` form (also the robust
    # form under bluez 5.86, where bare non-interactive subcommands are flaky).
    printf 'devices Paired\nquit\n' | bluetoothctl 2>/dev/null | awk '/^Device /{print $2}' | while read -r mac; do
      [ -z "$mac" ] && continue
      mac_under=$(echo "$mac" | tr ':' '_')
      pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -q "$mac_under" && continue
      if bluetoothctl info "$mac" 2>/dev/null | grep -qi "0000110b"; then
        name=$(bluetoothctl info "$mac" 2>/dev/null | awk '/^\tName:/{sub(/^\tName: /,""); print; exit}')
        [ -z "$name" ] && name="$mac"
        printf '__bt__%s|%s|0|1\n' "$mac" "$name"
      fi
    done
  '';

  # Print the node.name of the hardware mic currently feeding the RNNoise
  # filter (i.e. what capture.rnnoise_source is linked to), or nothing if the
  # filter isn't present. Used wherever rnnoise_source needs to resolve to the
  # real device behind it (device list, bar label, toggle-off restore).
  rnnoise-current-input-sh = pkgs.writeShellScriptBin "audio-rnnoise-current-input" ''
    # INTENT first: the target.object metadata set by audio-rnnoise-set-input.
    # Reading the first live link instead (old behaviour) is link-order
    # roulette whenever a stray second link exists — it made micblend-status
    # and the mix stand-down logic flap between answers.
    capid=$(${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.info.props["node.name"] == "capture.rnnoise_source") | .id' \
      | head -1)
    if [ -n "$capid" ]; then
      t=$(${pkgs.pipewire}/bin/pw-metadata "$capid" target.object 2>/dev/null \
        | ${pkgs.gawk}/bin/awk -F"'" "/key:'target.object'/ { print \$4; exit }")
      # Only trust the stored intent if that node still EXISTS. A mic that was
      # selected then removed (e.g. a disconnected network/USB mic) leaves stale
      # intent pointing at a dead node; trusting it blindly breaks the bar's
      # active-mic resolution. If it's gone, fall through to the live link.
      if [ -n "$t" ] && ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
           | ${pkgs.jq}/bin/jq -e --arg n "$t" 'any(.[]; .info.props["node.name"] == $n)' >/dev/null; then
        echo "$t"; exit 0
      fi
    fi
    # Fallback (no metadata yet, e.g. fresh boot): first live link.
    ${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk '
      /^capture\.rnnoise_source:input/ { f = 1; next }
      f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); sub(/:[^:]*$/, "", s); print s; exit }
      f && /^[^[:space:]]/ { f = 0 }
    '
  '';

  list-sources-sh = pkgs.writeShellScriptBin "audio-list-sources" ''
    default=$(pactl get-default-source 2>/dev/null)
    # When noise cancellation is on, rnnoise_source is the default but it is
    # represented by the toggle, not the device list. Highlight the hardware
    # mic actually feeding the filter instead, and hide rnnoise_source itself.
    if [ "$default" = "rnnoise_source" ]; then
      fin=$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)
      [ -n "$fin" ] && default="$fin"
    fi
    pactl list sources | awk -v def="$default" '
      ${audio-naming-awk}
      function emit(    bt, cur) {
        if (name == "") return
        # Internal plumbing never gets a mic row — the canonical
        # internal_node() mask decides (monitors, rnnoise_source — the
        # noise-cancel toggle, already resolved to its feed mic above —,
        # combined_mics, delay wrappers + loopbacks, snd_aloop, tailnet
        # mic plumbing incl. tailnet-rmic- consumed-mic remaps which show
        # as their mesh row instead, venmic screen-share source).
        if (internal_node(name)) return
        bt  = (name ~ /^bluez_/) ? 1 : 0
        cur = (name == def) ? "1" : "0"
        # 5th field: bar-style short name, for the per-mic bar widgets
        printf "%s|%s|%s|%s|%s\n", name, display_name(port, alsa_card, alsa_device, desc), cur, bt,
               short_name(port, alsa_card, alsa_device, desc)
      }
      /^Source #/ { emit()
                    name = ""; desc = ""; port = ""; alsa_card = ""; alsa_device = "" }
      /^\tName:/        { name = $2 }
      /^\tDescription:/ { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/ { port = $3 }
      /alsa\.card = /   { match($0, /"[^"]*"/); alsa_card   = substr($0, RSTART+1, RLENGTH-2) }
      /alsa\.device = / { match($0, /"[^"]*"/); alsa_device = substr($0, RSTART+1, RLENGTH-2) }
      END { emit() }
    '
    # Unconnected but PAIRED BT audio sources (Headset UUID: 0000111e).
    # Paired-only (see list-sinks): filter with the piped `devices Paired` form.
    printf 'devices Paired\nquit\n' | bluetoothctl 2>/dev/null | awk '/^Device /{print $2}' | while read -r mac; do
      [ -z "$mac" ] && continue
      mac_under=$(echo "$mac" | tr ':' '_')
      pactl list short sources 2>/dev/null | awk '{print $2}' | grep -q "$mac_under" && continue
      if bluetoothctl info "$mac" 2>/dev/null | grep -qi "0000111e"; then
        name=$(bluetoothctl info "$mac" 2>/dev/null | awk '/^\tName:/{sub(/^\tName: /,""); print; exit}')
        [ -z "$name" ] && name="$mac"
        printf '__bt__%s|%s|0|1\n' "$mac" "$name"
      fi
    done
  '';

  # ── Output duplication (sink-side MIX) ──────────────────────────────────
  # Dup ON = load pipewire-pulse's module-combine-sink (a `combined_out` sink
  # forwarding to every physical output) and make it the default; OFF = restore
  # the previous default and unload the module. The combine sink must NOT be
  # loaded statically: its device streams either never wake the sinks (passive
  # → apps hang) or keep them running from boot (non-passive → wedged the
  # Arctis in permanent XRUN). On-demand, always-running sinks are correct —
  # that's the whole point of MIX. State is derived from the live default
  # (picking a single sink reads as dup-off).
  outdup-status-sh = pkgs.writeShellScriptBin "audio-outdup-status" ''
    if [ "$(pactl get-default-sink 2>/dev/null)" = "combined_out" ]; then
      echo on
    else
      echo off
    fi
  '';

  # These three combine-management scripts use bare awk/grep/cat/pactl and are called
  # from MINIMAL-PATH systemd services (audio-devices, cast-sync, mesh hold-open). A
  # user service's PATH lacks gawk → bare `awk` is command-not-found → the script
  # silently no-ops mid-pipeline (this is the class of bug that made cast-sync never
  # apply). Make them self-contained: prepend the tools they need.
  combineToolPath = "${pkgs.pulseaudio}/bin:${pkgs.gawk}/bin:${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin";
  outdup-toggle-sh = pkgs.writeShellScriptBin "audio-outdup-toggle" ''
    export PATH="${combineToolPath}:$PATH"
    prevfile="$XDG_RUNTIME_DIR/qs-outdup-prev"
    have_combined() {
      pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF combined_out
    }
    default=$(pactl get-default-sink 2>/dev/null)
    if [ "$default" = "combined_out" ]; then
      prev=$(cat "$prevfile" 2>/dev/null)
      pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF "$prev" || prev=""
      # First real output as a fallback restore target — the canonical
      # internal_node() mask keeps snd_aloop and friends out of the running.
      [ -z "$prev" ] && prev=$(pactl list short sinks 2>/dev/null | awk '
        ${audio-naming-awk}
        $2 ~ /^(alsa_output|bluez_output)/ && !internal_node($2) { print $2; exit }')
      [ -z "$prev" ] && { echo "no sink to restore"; exit 1; }
      pactl set-default-sink "$prev"
      # Unload our combine sink (streams move back with the default swap
      # above). Match on args so unrelated combine sinks are left alone.
      pactl list short modules 2>/dev/null \
        | awk '$2 == "module-combine-sink" && $0 ~ /sink_name=combined_out/ { print $1 }' \
        | while read -r mid; do pactl unload-module "$mid"; done
    else
      [ -n "$default" ] && printf '%s\n' "$default" > "$prevfile"
      # Seed the mix-set with just this output if unset → MIX starts with ONLY
      # the current default output; add others via the chain-link.
      [ -n "$default" ] && ${mixset-mutate-sh}/bin/audio-mixset-mutate snk seed "$default" >/dev/null 2>&1
      if ! have_combined; then
        # Slaves come from the mix-set (chosen outputs) if any, else every
        # current sink minus the snd_aloop loopback (guest-gaming plumbing —
        # mirroring into it would pipe host audio into the guest capture side).
        # Trade-off vs bare load: a sink hotplugged while MIX is on isn't added
        # until MIX is re-toggled (or a chain-link toggle triggers a reload).
        slaves=$(${mixset-slaves-sh}/bin/audio-mixset-slaves)
        pactl load-module module-combine-sink sink_name=combined_out slaves="$slaves" >/dev/null
        # Bounded wait for the sink to materialise before pointing the
        # default at it (module load returns before the node exists).
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          have_combined && break
          sleep 0.2
        done
      fi
      pactl set-default-sink combined_out
    fi
    echo done
  '';

  # Comma-separated slave list for combined_out: the mix-set's chosen sinks
  # (intersected with what's actually present) if the set is non-empty, else
  # every present sink minus the snd_aloop loopback. Falls back to all if the
  # chosen set has no present members (never build an empty combine sink).
  mixset-slaves-sh = pkgs.writeShellScriptBin "audio-mixset-slaves" ''
    export PATH="${combineToolPath}:$PATH"
    cfg=${mixset-config-path}
    # Remote tailnet outputs are stored as their mesh id (`mesh:output:host:name`);
    # the audio-devices daemon keeps their route alive and writes the live proxy
    # sink name here so we can fold it into the combine slaves.
    proxymap="''${XDG_RUNTIME_DIR:-/tmp}/audio-mix/mesh-proxies"
    # Cast-sync: when ON, a real LOCAL slave X is served through its delay wrapper
    # `delayed.X` (spawned by the cast-sync daemon) so it lags to match the cast's
    # buffer. The cast sink (castaudio_*) and mesh proxies (tailnet-out-*) stay raw
    # — they are the network-buffered references everything else aligns to.
    sync_on=1
    [ -f "''${XDG_STATE_HOME:-$HOME/.local/state}/audio-cast-sync/disabled" ] && sync_on=0
    # Slave candidates: everything real, PLUS the two internal families that
    # ARE legitimate combine members and so get carved back in — delayed.<sink>
    # cast-sync wrappers (substituted for their real sink below) and cast
    # proxies (castaudio_/cast_, the cast IS a mix member). The rest of the
    # canonical internal_node() mask must never be slaved: combined_out itself,
    # the applvl pool, snd_aloop (mirroring into it would pipe host audio into
    # the guest capture side) and the tailnet mic sinks (mirroring into a
    # donated/consumed mic would echo output into that mic).
    present=$(pactl list short sinks 2>/dev/null | awk '
      ${audio-naming-awk}
      $2 ~ /^(delayed\.|castaudio_|cast_)/ || !internal_node($2) { print $2 }')
    # Mix-set entries to fold in: the configured .sinks[], or — when empty ("all
    # sinks" mode) — every present sink, run through the SAME loop below so the
    # cast-sync delay substitution applies in all-sinks mode too.
    entries=$([ -f "$cfg" ] && ${pkgs.jq}/bin/jq -r '(.sinks // [])[]' "$cfg" 2>/dev/null)
    [ -z "$entries" ] && entries="$present"
    slaves=""
    # Iterate line-by-line: mesh ids embed spaces (device names), so word-splitting
    # would shred them.
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      case "$s" in
        mesh:*)
          px=""
          [ -f "$proxymap" ] && px=$(${pkgs.gawk}/bin/awk -F'\t' -v k="$s" \
            '$1 == k { print $2; exit }' "$proxymap" 2>/dev/null)
          [ -n "$px" ] && printf '%s\n' "$present" | grep -qxF "$px" \
            && slaves="$slaves''${slaves:+,}$px" ;;
        *)
          printf '%s\n' "$present" | grep -qxF "$s" || continue
          emit="$s"
          case "$s" in
            alsa_*|bluez_*)
              if [ "$sync_on" = 1 ] \
                 && printf '%s\n' "$present" | grep -qxF "delayed.$s"; then
                emit="delayed.$s"
              fi ;;
          esac
          slaves="$slaves''${slaves:+,}$emit" ;;
      esac
    done < <(printf '%s\n' "$entries")
    [ -z "$slaves" ] && slaves=$(printf '%s\n' "$present" | ${pkgs.coreutils}/bin/paste -sd,)
    printf '%s\n' "$slaves"
  '';

  # Rebuild combined_out with the current mix-set slaves — but only if the
  # output-duplicate is live (default == combined_out). Called when the sink
  # mix-set changes so edits apply immediately. Parks the default on a real sink
  # during the swap so streams aren't orphaned, then points it back.
  outdup-reload-sh = pkgs.writeShellScriptBin "audio-outdup-reload" ''
    export PATH="${combineToolPath}:$PATH"
    [ "$(pactl get-default-sink 2>/dev/null)" = "combined_out" ] || exit 0
    slaves=$(${mixset-slaves-sh}/bin/audio-mixset-slaves)
    [ -z "$slaves" ] && exit 0
    safe=$(cat "$XDG_RUNTIME_DIR/qs-outdup-prev" 2>/dev/null)
    # Same fallback rule as outdup-toggle: first real output, with the
    # canonical internal_node() mask keeping snd_aloop and friends out.
    pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF "$safe" || \
      safe=$(pactl list short sinks 2>/dev/null | awk '
        ${audio-naming-awk}
        $2 ~ /^(alsa_output|bluez_output)/ && !internal_node($2) { print $2; exit }')
    [ -n "$safe" ] && pactl set-default-sink "$safe"
    pactl list short modules 2>/dev/null \
      | awk '$2 == "module-combine-sink" && $0 ~ /sink_name=combined_out/ { print $1 }' \
      | while read -r mid; do pactl unload-module "$mid"; done
    pactl load-module module-combine-sink sink_name=combined_out slaves="$slaves" >/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF combined_out && break
      sleep 0.2
    done
    pactl set-default-sink combined_out
    echo done
  '';

  # One line per output fed by combined_out, for the per-sink mixer rows in
  # the output popup: `<streamId>|<sink node.name>|<display>|<vol%>` — the
  # streamId is the duplicator's playback stream (a sink-input) on that sink,
  # whose volume is that device's level in the duplicated output.
  list-dup-sinks-sh = pkgs.writeShellScriptBin "audio-list-dup-sinks" ''
    sinks=$(pactl list sinks | awk '
      ${audio-naming-awk}
      # This lookup map deliberately keeps the two internal families that ARE
      # legitimate combine members (mirroring the mixset-slaves carve-out):
      # delayed.<sink> cast-sync wrappers (re-labelled to the real device
      # below) and cast proxies (castaudio_/cast_). Everything else in the
      # canonical internal_node() mask is dropped so internal plumbing —
      # which mixset-slaves refuses to slave anyway — never grows a mixer row.
      function keep(n) { return n ~ /^(delayed\.|castaudio_|cast_)/ || !internal_node(n) }
      function emit() { if (name != "" && keep(name)) printf "%s|%s|%s\n", idx, name, display_name(port, alsa_card, alsa_device, desc) }
      /^Sink #/ { emit(); idx = substr($2, 2); name=""; desc=""; port=""; alsa_card=""; alsa_device="" }
      /^\tName:/        { name = $2 }
      /^\tDescription:/ { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/ { port = $3 }
      /alsa\.card = /   { match($0, /"[^"]*"/); alsa_card   = substr($0, RSTART+1, RLENGTH-2) }
      /alsa\.device = / { match($0, /"[^"]*"/); alsa_device = substr($0, RSTART+1, RLENGTH-2) }
      END { emit() }
    ')
    pactl list sink-inputs | awk -v SNK="$sinks" '
      BEGIN {
        n = split(SNK, lines, "\n")
        for (i = 1; i <= n; i++) {
          split(lines[i], f, "|")
          snkname[f[1]] = f[2]; snkdisp[f[1]] = f[3]
          dispByName[f[2]] = f[3]
        }
        # A cast-sync delay wrapper (delayed.<sink>) stands in for its real output
        # while SYNC is on: show the row under the real device name, not the
        # wrapper (cast sync) description, so the mixer stays recognisable.
        for (k in snkname) {
          if (snkname[k] ~ /^delayed\./) {
            real = substr(snkname[k], 9)
            if (real in dispByName) snkdisp[k] = dispByName[real]
          }
        }
      }
      function flush() {
        if (id != "" && nodename ~ /^output\.combined_out/ && (snkidx in snkname))
          printf "%s|%s|%s|%s\n", id, snkname[snkidx], snkdisp[snkidx], vol
      }
      /^Sink Input #/      { flush(); id = substr($3, 2); snkidx=""; vol=""; nodename="" }
      /^[[:space:]]*Sink:/ { snkidx = $2 }
      /^[[:space:]]*Volume:/ { if (vol == "") { match($0, /[0-9]+%/); vol = substr($0, RSTART, RLENGTH-1) } }
      /node\.name = /      { split($0, a, "\""); nodename = a[2] }
      END { flush() }
    '
  '';

  # ── RNNoise input toggle ────────────────────────────────────────────────
  # The pipewire filter-chain in flakes/audio/pipewire.nix exposes a virtual
  # "rnnoise_source". Toggling = switching the default source between it and
  # the hardware mic. The previous (hardware) source is remembered so toggling
  # back restores exactly what was selected before.

  # Point the filter stack's intake at a specific hardware mic. The intake
  # (capture.rnnoise_source — since the AEC stage landed this is the
  # echo-cancel capture, which holds the interface name; see
  # flakes/audio/pipewire.nix) is a passive stream that does NOT auto-follow
  # the default once rnnoise_source itself is the default, so we retarget it
  # explicitly via the node's target.object metadata.
  rnnoise-set-input-sh = pkgs.writeShellScriptBin "audio-rnnoise-set-input" ''
    mic="$1"
    [ -z "$mic" ] && exit 0
    capid=$(${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.info.props["node.name"] == "capture.rnnoise_source") | .id' \
      | head -1)
    [ -n "$capid" ] && ${pkgs.pipewire}/bin/pw-metadata "$capid" target.object "$mic" >/dev/null 2>&1
    # Sweep stray links: WirePlumber moves ITS link to the new target, but
    # manually created links (auto-mic crossfade, past bugs) survive metadata
    # retargets and leave the filter fed by TWO sources at once — with the
    # sync wrappers' 45 ms delay that's an audible echo, and it made every
    # link-order-based status reader flap. Anything not matching the new
    # target gets unlinked; WirePlumber re-adds the right one if we race it.
    ${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk -v want="$mic" '
      /^capture\.rnnoise_source:input/ { f = 1; next }
      f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); print s }
      f && /^[^[:space:]]/ { f = 0 }
    ' | while IFS= read -r srcport; do
      case "$srcport" in
        "$mic":*) ;;   # the intended feed stays
        *) ${pkgs.pipewire}/bin/pw-link -d "$srcport" "capture.rnnoise_source:input_MONO" 2>/dev/null ;;
      esac
    done
    # AEC bypassed? Then the inner chain capture is parked on the mic
    # DIRECTLY (audio-aec-set off) and must follow the selection too, or it
    # would keep reading the old mic. Same retarget + sweep discipline.
    if [ "$(cat "$XDG_RUNTIME_DIR/qs-aec-on" 2>/dev/null)" = "off" ]; then
      innerid=$(${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r '.[] | select(.info.props["node.name"] == "capture.rnnoise_source.filter") | .id' \
        | head -1)
      if [ -n "$innerid" ]; then
        ${pkgs.pipewire}/bin/pw-metadata "$innerid" target.object "$mic" >/dev/null 2>&1
        ${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk -v want="$mic" '
          /^capture\.rnnoise_source\.filter:input_MONO/ { f = 1; next }
          f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); print s }
          f && /^[^[:space:]]/ { f = 0 }
        ' | while IFS= read -r srcport; do
          case "$srcport" in
            "$mic":*) ;;
            *) ${pkgs.pipewire}/bin/pw-link -d "$srcport" "capture.rnnoise_source.filter:input_MONO" 2>/dev/null ;;
          esac
        done
      fi
    fi
    echo done
  '';

  # Denoise on/off is now an IN-GRAPH BYPASS (dry/wet mixer in the filter-chain,
  # see flakes/audio/pipewire.nix) — NOT a default-device swap. rnnoise_source stays
  # the default either way; we just flip the mixer gains. State is tracked in a
  # runtime file (the filter-chain boots filtering-ON).
  #   filter ON  -> Gain 1 (dry) = 0, Gain 2 (wet) = 1
  #   filter OFF -> Gain 1 (dry) = 1, Gain 2 (wet) = 0
  rnnoise-set-filter-sh = pkgs.writeShellScriptBin "audio-rnnoise-set-filter" ''
    want="$1"   # "on" or "off"
    statefile="$XDG_RUNTIME_DIR/qs-rnnoise-on"
    id=$(${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.info.props["node.name"] == "rnnoise_source") | .id' \
      | head -1)
    [ -z "$id" ] && { echo "no rnnoise_source"; exit 1; }
    if [ "$want" = "off" ]; then dry=1.0; wet=0.0; else dry=0.0; wet=1.0; fi
    ${pkgs.pipewire}/bin/pw-cli set-param "$id" Props \
      "{ params = [ \"mix:Gain 1\" $dry \"mix:Gain 2\" $wet ] }" >/dev/null 2>&1
    printf '%s\n' "$want" > "$statefile"
    # Tell the auto-mic daemon to re-evaluate (filter on/off changes whether the
    # virtual source is the default vs. stepping aside to real devices).
    ${pkgs.procps}/bin/pkill -HUP -f auto-mic-daemon.py 2>/dev/null || true
    echo done
  '';

  rnnoise-toggle-sh = pkgs.writeShellScriptBin "audio-rnnoise-toggle" ''
    statefile="$XDG_RUNTIME_DIR/qs-rnnoise-on"
    cur=$(cat "$statefile" 2>/dev/null)
    [ -z "$cur" ] && cur=on            # filter-chain boots ON
    if [ "$cur" = "on" ]; then ${rnnoise-set-filter-sh}/bin/audio-rnnoise-set-filter off; else ${rnnoise-set-filter-sh}/bin/audio-rnnoise-set-filter on; fi
  '';

  rnnoise-status-sh = pkgs.writeShellScriptBin "audio-rnnoise-status" ''
    cur=$(cat "$XDG_RUNTIME_DIR/qs-rnnoise-on" 2>/dev/null)
    [ -z "$cur" ] && cur=on            # filter-chain boots ON
    echo "$cur"
  '';

  # ── Echo-cancel (AEC) bypass ────────────────────────────────────────────
  # The echo-cancel stage (flakes/audio/pipewire.nix) is bypassed by
  # retargeting the inner rnnoise-chain capture (capture.rnnoise_source.filter)
  # between the cancelled output `aec_source` (AEC on) and whatever currently
  # feeds the AEC intake (AEC off — the chain then reads the mic directly and
  # the AEC nodes idle out of path). State in $XDG_RUNTIME_DIR/qs-aec-on; the
  # graph boots ON. ALWAYS sweep stray links after the retarget: a metadata
  # move can leave the old link behind, feeding the filter from BOTH paths at
  # once — audibly doubled voice (bitten live 2026-10-03), the same failure
  # mode the set-input sweep exists for on the intake node.
  aec-set-sh = pkgs.writeShellScriptBin "audio-aec-set" ''
    want="$1"   # "on" or "off"
    case "$want" in on|off) ;; *) echo "usage: audio-aec-set on|off" >&2; exit 1 ;; esac
    statefile="$XDG_RUNTIME_DIR/qs-aec-on"
    # Best-effort id for the target.object metadata hint (pw-dump can stall
    # on a complex graph; a timeout keeps the toggle responsive). Linking
    # below works off node NAMES, so a missing id only skips the WP hint.
    innerid=$(timeout 8 ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.info.props["node.name"] == "capture.rnnoise_source.filter") | .id' \
      | head -1)
    if [ "$want" = "on" ]; then
      tgt="aec_source"
    else
      # Bypass = read the same feed the AEC intake is on (selected mic or
      # combined_mics). If that can't be resolved, FAIL rather than guess —
      # leaving AEC on is always safe for routing.
      tgt=$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)
      [ -z "$tgt" ] && { echo "cannot resolve current mic"; exit 1; }
    fi
    [ -n "$innerid" ] && ${pkgs.pipewire}/bin/pw-metadata "$innerid" target.object "$tgt" >/dev/null 2>&1
    # Sweep any link that ISN'T the intended feed.
    ${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk -v want="$tgt" '
      /^capture\.rnnoise_source\.filter:input_MONO/ { f = 1; next }
      f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); print s }
      f && /^[^[:space:]]/ { f = 0 }
    ' | while IFS= read -r srcport; do
      case "$srcport" in
        "$tgt":*) ;;   # the intended feed stays
        *) ${pkgs.pipewire}/bin/pw-link -d "$srcport" "capture.rnnoise_source.filter:input_MONO" 2>/dev/null ;;
      esac
    done
    # GUARANTEE the intended link exists rather than trusting target.object.
    # WirePlumber's metadata-driven reconnect RACES at graph (re)build: on a
    # cold pipewire start aec_source may not exist yet when the filter is
    # placed, and an AEC toggle can leave the input orphaned — a dead-silent
    # mic that survives until something relinks it (cost whole calls over
    # 2026-10-09). pw-link by name is idempotent, so re-asserting is safe.
    have=$(${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk -v t="$tgt" '
      /^capture\.rnnoise_source\.filter:input_MONO/ { f = 1; next }
      f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); if (index(s, t ":") == 1) h = 1 }
      f && /^[^[:space:]]/ { f = 0 }
      END { print h + 0 }')
    if [ "$have" != 1 ]; then
      srcport=$(${pkgs.pipewire}/bin/pw-link -o 2>/dev/null | ${pkgs.gnugrep}/bin/grep -m1 "^$tgt:")
      [ -n "$srcport" ] && ${pkgs.pipewire}/bin/pw-link "$srcport" "capture.rnnoise_source.filter:input_MONO" 2>/dev/null
    fi
    printf '%s\n' "$want" > "$statefile"
    echo done
  '';

  aec-status-sh = pkgs.writeShellScriptBin "audio-aec-status" ''
    cur=$(cat "$XDG_RUNTIME_DIR/qs-aec-on" 2>/dev/null)
    [ -z "$cur" ] && cur=on            # the graph boots with AEC in path
    echo "$cur"
  '';

  # Auto-drive the AEC from the DEFAULT OUTPUT class: speakers (room playback
  # the mic can hear) → on; headphones/headsets (no acoustic echo path) → off.
  # On headphones webrtc has no real echo to converge on, and its residual
  # suppressor eats the near-end voice whenever the reference is active
  # instead. Event-driven via pactl subscribe (no polling): re-evaluates on
  # sink/server/card events (default switches, port changes, hotplug).
  #
  # Classification: only sinks we positively KNOW are headphones (name/port/
  # description/form-factor mentioning headphone/headset, or bluez devices —
  # which on this setup are always worn audio) bypass the AEC; EVERYTHING else (speakers,
  # line-out, HDMI, dock digital outs, unknown) keeps it on. An IEC958 dock
  # output feeding room speakers was misread as headphones under the old
  # default-off rule, leaving room music uncancelled on the mic (2026-10-05).
  aec-auto-daemon-sh = pkgs.writeShellScriptBin "audio-aec-auto-daemon" ''
    classify() {
      def=$(${pkgs.pulseaudio}/bin/pactl get-default-sink 2>/dev/null)
      [ -z "$def" ] && return 1
      {
        printf '%s\n' "$def"
        ${pkgs.pulseaudio}/bin/pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk -v def="$def" '
          /^Sink #/   { inblk = 0 }
          /^\tName:/  { inblk = ($2 == def) }
          inblk && (/^\tDescription:/ || /^\tActive Port:/ || /device\.form_factor/) { print }
        '
      } | ${pkgs.gnugrep}/bin/grep -qiE 'headphone|headset|bluez' \
        && echo headphones || echo speaker
    }
    # Cheap check (pw-link only): is the filter input already wired to the
    # feed the CURRENT AEC state implies? Lets source events repair an
    # orphaned link without the cost of re-classifying the output.
    link_ok() {
      if [ "$(${aec-status-sh}/bin/audio-aec-status)" = on ]; then
        t=aec_source
      else
        t=$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)
      fi
      [ -z "$t" ] && return 0   # can't resolve — don't thrash
      ${pkgs.pipewire}/bin/pw-link -l 2>/dev/null | ${pkgs.gawk}/bin/awk -v t="$t" '
        /^capture\.rnnoise_source\.filter:input_MONO/ { f = 1; next }
        f && /\|<-/ { s = $0; sub(/.*\|<-[ ]*/, "", s); if (index(s, t ":") == 1) ok = 1 }
        f && /^[^[:space:]]/ { f = 0 }
        END { exit !ok }'
    }
    # Re-establish the link for the current state without re-classifying.
    repair_link() {
      link_ok || ${aec-set-sh}/bin/audio-aec-set "$(${aec-status-sh}/bin/audio-aec-status)"
    }
    evaluate() {
      case "$(classify)" in
        speaker) want=on ;;
        headphones) want=off ;;
        *) return 0 ;;   # no default sink yet — leave as-is
      esac
      cur=$(${aec-status-sh}/bin/audio-aec-status)
      # Re-assert when the desired STATE changed OR the link drifted/orphaned.
      # A graph rebuild (pipewire restart) or an AEC toggle can leave the
      # filter input unlinked even though the state is nominally right — a
      # dead-silent mic (2026-10-09). audio-aec-set re-creates the link.
      if [ "$cur" != "$want" ] || ! link_ok; then
        ${aec-set-sh}/bin/audio-aec-set "$want"
      fi
    }
    evaluate
    ${pkgs.pulseaudio}/bin/pactl subscribe | while IFS= read -r line; do
      case "$line" in
        *" on server"*|*" on sink"*|*" on card"*) evaluate ;;
        # aec_source (re)appearing after a graph rebuild is a SOURCE event;
        # repair the link without the full re-classify on this hot path.
        *" on source"*) repair_link ;;
      esac
    done
  '';

  # ── USB output headroom (device-side buffer) ────────────────────────────
  # Extra ALSA buffer on USB sinks guards against xruns/crackle when the CPU
  # is saturated (Star Citizen), at the cost of output latency (48 samples =
  # 1ms at 48kHz). Applied live via the node Props param — no wireplumber
  # restart — and tracked in a runtime file (devices boot at headroom 0, so
  # rhythm games keep minimum latency unless the slider says otherwise).
  usb-headroom-set-sh = pkgs.writeShellScriptBin "audio-headroom-set" ''
    samples="$1"
    case "$samples" in "" | *[!0-9]*) exit 1 ;; esac
    for id in $(${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
      | ${pkgs.jq}/bin/jq '.[] | select((.info.props["node.name"] // "") | startswith("alsa_output.usb-")) | .id'); do
      ${pkgs.pipewire}/bin/pw-cli set-param "$id" Props \
        "{ params = [ \"api.alsa.headroom\" $samples ] }" >/dev/null 2>&1
    done
    printf '%s\n' "$samples" > "$XDG_RUNTIME_DIR/qs-usb-headroom"
    echo done
  '';

  usb-headroom-status-sh = pkgs.writeShellScriptBin "audio-headroom-status" ''
    cur=$(cat "$XDG_RUNTIME_DIR/qs-usb-headroom" 2>/dev/null)
    [ -z "$cur" ] && cur=0
    echo "$cur"
  '';

  # Passive crackle guard daemon (systemd user service `audio-xrun-guard`,
  # see quickshell/default.nix; toggled by the AUTO chip next to the buf
  # slider). Watches pw-top's xrun counter on USB sinks and escalates the
  # headroom one step per burst of underruns (256 → 512 → 1024 → 2048,
  # ≥5s apart); after 5 quiet minutes it steps back down towards 0. It reads
  # the shared statefile before every change, so manual slider moves are
  # respected as the new baseline, and every change it makes shows up on the
  # slider. pw-top only receives profiler data while the graph is actually
  # processing, so the daemon is effectively free when no audio plays.
  audio-xrun-guard-sh = pkgs.writeShellScriptBin "audio-xrun-guard" ''
    # OUTPUT sinks boot at headroom 0 (rhythm games want minimum latency) and
    # the slider shares this statefile. CAPTURE devices boot at the
    # wireplumber base (53-usb-capture-headroom = 512) and have NO slider, so
    # the guard escalates above that floor and decays back DOWN to it, never
    # below — a full-speed USB mic (PodMic) that the guard previously ignored
    # entirely is now covered too (2026-10-09).
    out_state="$XDG_RUNTIME_DIR/qs-usb-headroom"
    cap_state="$XDG_RUNTIME_DIR/qs-usb-capture-headroom"
    CAP_FLOOR=512   # keep in sync with 53-usb-capture-headroom in pipewire.nix

    # read a statefile with a default when empty/corrupt: read_state FILE DEFAULT
    read_state() {
      c=$(cat "$1" 2>/dev/null)
      case "$c" in "" | *[!0-9]*) echo "$2" ;; *) echo "$c" ;; esac
    }

    # apply_nodes PREFIX SAMPLES STATEFILE
    apply_nodes() {
      ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
        | ${pkgs.jq}/bin/jq --arg p "$1" '.[] | select((.info.props["node.name"] // "") | startswith($p)) | .id' \
        | while read -r id; do
            ${pkgs.pipewire}/bin/pw-cli set-param "$id" Props \
              "{ params = [ \"api.alsa.headroom\" $2 ] }" >/dev/null 2>&1 || true
          done
      printf '%s\n' "$2" > "$3"
    }

    # awk emits "o" when a USB SINK's ERR rises, "i" when a USB SOURCE's does.
    # The ERR column index is read from pw-top's own header (layout varies by
    # version — this one splits W/Q and B/Q so ERR is field 9; a hard-coded
    # field 8 caught the load ratio and fired constantly). read -t turns 5
    # xrun-free minutes into a decay step.
    ${pkgs.pipewire}/bin/pw-top -b 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '
          $1 == "S" && $2 == "ID" {
            for (i = 1; i <= NF; i++) if ($i == "ERR") erridx = i
            next
          }
          erridx && $NF ~ /^alsa_output\.usb-/ {
            if ($NF in last && $erridx > last[$NF]) { print "o"; fflush() }
            last[$NF] = $erridx
          }
          erridx && $NF ~ /^alsa_input\.usb-/ {
            if ($NF in last && $erridx > last[$NF]) { print "i"; fflush() }
            last[$NF] = $erridx
          }' \
      | {
        last_o=0
        last_i=0
        while :; do
          ret=0
          read -r -t 300 tag || ret=$?
          if [ "$ret" -eq 0 ]; then
            now=$(date +%s)
            case "$tag" in
              o)
                [ $((now - last_o)) -lt 5 ] && continue
                last_o=$now
                c=$(read_state "$out_state" 0)
                if [ "$c" -lt 256 ]; then apply_nodes "alsa_output.usb-" 256 "$out_state"
                elif [ "$c" -lt 2048 ]; then apply_nodes "alsa_output.usb-" $((c * 2)) "$out_state"
                fi ;;
              i)
                [ $((now - last_i)) -lt 5 ] && continue
                last_i=$now
                c=$(read_state "$cap_state" "$CAP_FLOOR")
                if [ "$c" -lt 2048 ]; then
                  n=$((c * 2)); [ "$n" -lt "$CAP_FLOOR" ] && n=$CAP_FLOOR
                  apply_nodes "alsa_input.usb-" "$n" "$cap_state"
                fi ;;
            esac
          elif [ "$ret" -gt 128 ]; then
            # 5 quiet minutes — decay both toward their floors (out:0, cap:512)
            c=$(read_state "$out_state" 0)
            if [ "$c" -gt 0 ]; then n=$((c / 2)); [ "$n" -lt 256 ] && n=0; apply_nodes "alsa_output.usb-" "$n" "$out_state"; fi
            c=$(read_state "$cap_state" "$CAP_FLOOR")
            if [ "$c" -gt "$CAP_FLOOR" ]; then n=$((c / 2)); [ "$n" -lt "$CAP_FLOOR" ] && n=$CAP_FLOOR; apply_nodes "alsa_input.usb-" "$n" "$cap_state"; fi
          else
            break     # pw-top went away (pipewire restart) — service restarts us
          fi
        done
      }
  '';

  # Guard on/off = whether the user service runs. It is ON BY DEFAULT: the
  # unit only skips startup when the DISABLE flag exists (its
  # ConditionPathExists=!… checks for it), so the toggle creates/removes that
  # flag to make an opt-out stick across logins.
  xrun-guard-status-sh = pkgs.writeShellScriptBin "audio-xrun-guard-status" ''
    if ${pkgs.systemd}/bin/systemctl --user is-active -q audio-xrun-guard 2>/dev/null; then
      echo on
    else
      echo off
    fi
  '';

  xrun-guard-toggle-sh = pkgs.writeShellScriptBin "audio-xrun-guard-toggle" ''
    flag="''${XDG_CONFIG_HOME:-$HOME/.config}/qs-audio-xrun-guard-disabled"
    if ${pkgs.systemd}/bin/systemctl --user is-active -q audio-xrun-guard 2>/dev/null; then
      ${pkgs.systemd}/bin/systemctl --user stop audio-xrun-guard
      touch "$flag"
    else
      rm -f "$flag"
      ${pkgs.systemd}/bin/systemctl --user start audio-xrun-guard
    fi
    echo done
  '';

  # ── Mic blend (multi-mic mixing) toggle ─────────────────────────────────
  # flakes/audio/pipewire.nix exposes `combined_mics`, a combine-stream source that
  # mixes every physical mic. Blend ON = route it into the audio stack; OFF =
  # back to the single mic that was selected before. There is deliberately no
  # state file: on/off is DERIVED from the live graph (what actually feeds the
  # stack), so picking a single mic in the device list naturally reads as
  # blend-off without extra bookkeeping.
  #
  # Two routing modes, mirroring the rnnoise plumbing:
  #  - system active (rnnoise_source is the default): retarget the filter's
  #    capture at combined_mics — blend feeds THROUGH the denoiser.
  #  - escape hatch (both filter and auto-switch off, real device is default):
  #    set the default source to combined_mics directly.
  micblend-status-sh = pkgs.writeShellScriptBin "audio-micblend-status" ''
    default=$(pactl get-default-source 2>/dev/null)
    if [ "$default" = "combined_mics" ]; then echo on; exit 0; fi
    if [ "$default" = "rnnoise_source" ] \
       && [ "$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)" = "combined_mics" ]; then
      echo on
    else
      echo off
    fi
  '';

  micblend-set-sh = pkgs.writeShellScriptBin "audio-micblend-set" ''
    want="$1"   # "on" or "off"
    prevfile="$XDG_RUNTIME_DIR/qs-micblend-prev"
    default=$(pactl get-default-source 2>/dev/null)
    # First hardware mic, the fallback when there's no remembered previous mic.
    first_mic() {
      pactl list short sources 2>/dev/null | awk '
        $2 ~ /^(alsa_input|bluez_input)/ { print $2; exit }'
    }
    if [ "$want" = "on" ]; then
      # Stand the auto-mic daemon down FIRST (suspend remembers it was on, so
      # MIX-off below restores it — a plain set-enabled 0 here silently lost
      # auto-switch for days). The mutate tool HUPs the daemon, so it has
      # dropped its meters before the blend takes over the routing.
      ${auto-mic-mutate-sh}/bin/audio-auto-mic-mutate suspend >/dev/null 2>&1 || true
      if [ "$default" = "rnnoise_source" ]; then
        cur=$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)
        [ -n "$cur" ] && [ "$cur" != "combined_mics" ] && printf '%s\n' "$cur" > "$prevfile"
        ${rnnoise-set-input-sh}/bin/audio-rnnoise-set-input combined_mics
      else
        [ -n "$default" ] && [ "$default" != "combined_mics" ] && printf '%s\n' "$default" > "$prevfile"
        pactl set-default-source combined_mics
      fi
      # Seed the mix-set with just this mic if it's unset, so MIX starts with
      # ONLY the current default mic (add others via the chain-link) rather than
      # blending everything. prevfile now holds exactly that mic.
      seed_mic=$(cat "$prevfile" 2>/dev/null)
      [ -n "$seed_mic" ] && ${mixset-mutate-sh}/bin/audio-mixset-mutate src seed "$seed_mic" >/dev/null 2>&1
      # Tell the auto-mic daemon to stand down IMMEDIATELY (it otherwise
      # re-routes a single mic over the blend on the next speech window,
      # which reads as "MIX turned itself off" + an echo); and nudge the
      # mix-sync daemon so combined_mics narrows to the seeded set.
      ${pkgs.procps}/bin/pkill -HUP -f auto-mic-daemon.py 2>/dev/null || true
      ${pkgs.procps}/bin/pkill -USR1 -f mix-sync-daemon.py 2>/dev/null || true
    else
      # Stand automix down FIRST: while enabled it re-pins combined_mics
      # within ~1 s of any retarget (verified 2026-10-07), so an OFF that
      # leaves it running is silently reverted and the MIX toggle appears
      # stuck on. Mutate HUPs the daemon, which drops the pin before the
      # retarget below.
      ${automix-mutate-sh}/bin/audio-automix-mutate set-enabled 0 >/dev/null 2>&1 || true
      prev=$(cat "$prevfile" 2>/dev/null)
      # Only restore a mic that still exists; otherwise fall back.
      pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qxF "$prev" || prev=""
      [ -z "$prev" ] && prev=$(first_mic)
      [ -z "$prev" ] && { echo "no mic to restore"; exit 1; }
      if [ "$default" = "rnnoise_source" ]; then
        ${rnnoise-set-input-sh}/bin/audio-rnnoise-set-input "$prev"
      else
        pactl set-default-source "$prev"
      fi
      # ...and resume single-mic duty: restore auto-switch if the suspend
      # above disabled it (no-op otherwise). The mutate tool HUPs the daemon,
      # which re-evaluates meters + feed belief against the restored routing.
      ${auto-mic-mutate-sh}/bin/audio-auto-mic-mutate resume >/dev/null 2>&1 || true
    fi
    echo done
  '';

  micblend-toggle-sh = pkgs.writeShellScriptBin "audio-micblend-toggle" ''
    if [ "$(${micblend-status-sh}/bin/audio-micblend-status)" = "on" ]; then
      ${micblend-set-sh}/bin/audio-micblend-set off
    else
      ${micblend-set-sh}/bin/audio-micblend-set on
    fi
  '';

  # One line per mic feeding the combined_mics blend, for the per-mic mixer
  # rows in the input popup: `<streamId>|<source node.name>|<display>|<vol%>`
  # streamId is the combiner's capture stream (a source-output) for that mic —
  # its volume IS the mic's level in the blend, the same knob pavucontrol
  # shows on its Recording tab.
  list-blend-mics-sh = pkgs.writeShellScriptBin "audio-list-blend-mics" ''
    # idx|name|display for every source, to resolve each combiner stream's
    # "Source:" index into the mic behind it. Deliberately NOT run through
    # internal_node(): this map is lookup-only (rows are bounded by what
    # capture.combined_mics* actually captures) and it MUST contain the
    # delayed.* wrappers so they can be unwrapped to the real mic below.
    # Explicit store paths: this script is also exec'd from daemons whose
    # systemd PATH has no awk — bare `awk` made blend_streams() silently
    # empty inside the automix daemon (gain engine no-op'd, 2026-10-05).
    sources=$(${pkgs.pulseaudio}/bin/pactl list sources | ${pkgs.gawk}/bin/awk '
      ${audio-naming-awk}
      function emit() { if (name != "") printf "%s|%s|%s\n", idx, name, display_name(port, alsa_card, alsa_device, desc) }
      /^Source #/ { emit(); idx = substr($2, 2); name=""; desc=""; port=""; alsa_card=""; alsa_device="" }
      /^\tName:/        { name = $2 }
      /^\tDescription:/ { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/ { port = $3 }
      /alsa\.card = /   { match($0, /"[^"]*"/); alsa_card   = substr($0, RSTART+1, RLENGTH-2) }
      /alsa\.device = / { match($0, /"[^"]*"/); alsa_device = substr($0, RSTART+1, RLENGTH-2) }
      END { emit() }
    ')
    ${pkgs.pulseaudio}/bin/pactl list source-outputs | ${pkgs.gawk}/bin/awk -v SRC="$sources" '
      BEGIN {
        n = split(SRC, lines, "\n")
        for (i = 1; i <= n; i++) {
          split(lines[i], f, "|")
          srcname[f[1]] = f[2]; srcdisp[f[1]] = f[3]
          namedisp[f[2]] = f[3]   # name-keyed, to resolve delay wrappers
        }
      }
      function flush(    nm, dp, real) {
        if (id != "" && nodename ~ /^capture\.combined_mics/ && (srcidx in srcname)) {
          nm = srcname[srcidx]; dp = srcdisp[srcidx]
          # combined_mics captures the audio-mix-sync `delayed.<mic>` wrappers;
          # present them as the real mic underneath
          if (nm ~ /^delayed\./) {
            real = substr(nm, 9)
            if (real in namedisp) dp = namedisp[real]
            nm = real
          }
          printf "%s|%s|%s|%s\n", id, nm, dp, vol
        }
      }
      /^Source Output #/     { flush(); id = substr($3, 2); srcidx=""; vol=""; nodename="" }
      /^[[:space:]]*Source:/ { srcidx = $2 }
      /^[[:space:]]*Volume:/ { if (vol == "") { match($0, /[0-9]+%/); vol = substr($0, RSTART, RLENGTH-1) } }
      /node\.name = /        { split($0, a, "\""); nodename = a[2] }
      END { flush() }
    '
  '';

  # Whether the mic is actively being used — drives the red bar indicator.
  # "yes" if mic-users (the spoof-resistant enumerator: real-mic capture by
  # server-side topology + raw-device holders) reports anything NOT on the
  # manual exclude list. Using the same source as the dropdown means the always-
  # visible indicator is as hard to spoof as the list, and catches direct-ALSA.
  #
  # EXCLUDE: processes that read the mic but shouldn't flash the indicator (e.g.
  # level meters). One per line; matched against the advertised name OR the exe
  # basename. Edit this list to taste.
  mic-inuse-sh = pkgs.writeShellScriptBin "audio-mic-inuse" ''
        exclude='PulseAudio Volume Control
    pavucontrol
    .pavucontrol-wrapped'

        inuse=no
        while IFS='|' read -r kind name exe pid; do
          [ -z "$kind" ] && continue
          base="''${exe##*/}"
          skip=no
          while IFS= read -r ex; do
            [ -z "$ex" ] && continue
            if [ "$ex" = "$name" ] || [ "$ex" = "$base" ]; then skip=yes; break; fi
          done <<EXCL
    $exclude
    EXCL
          [ "$skip" = yes ] && continue
          inuse=yes
          break
        done <<USERS
    $(${mic-users-sh}/bin/audio-mic-users)
    USERS
        echo "$inuse"
  '';

  # Lists what is currently using the microphone, for the input dropdown. One
  # line per user: `kind|displayName|exe|pid`.
  #   kind = "pw"  → a PipeWire capture stream (normal apps)
  #   kind = "raw" → a process holding the raw ALSA capture device that ISN'T
  #                  PipeWire/WirePlumber (i.e. capturing directly, bypassing
  #                  the graph) — surfaced as a warning row.
  #   kind = "sys" → (only with `--all`) an always-on/system capture that the
  #                  default listing deliberately hides — the shell's own
  #                  level-meter/VAD taps, the rnnoise filter and mic-combiner
  #                  node captures, the voice assistant's wake-word recorder,
  #                  the replay buffer — with a human-readable label. Streams
  #                  that tap PLAYBACK rather than the mic (corked streams,
  #                  sink monitors, `parec --monitor-stream` readers) stay
  #                  dropped in BOTH modes: they are not mic consumers.
  # Without `--all` the output is exactly the historical listing.
  # Trust model: existence comes from the kernel fd table + server-side PipeWire
  # topology, and FILTERING decisions use the kernel's view (the connected
  # source's monitor flag, and each holder's real /proc/PID/exe) — never the
  # client-set application.name / node.name / stream.monitor, which a process
  # can spoof. The advertised name is shown in the list purely for readability;
  # the exe (kernel truth) is what the UI reveals on hover. Defeated only by
  # root/kernel-level access, which is out of scope.
  mic-users-sh = pkgs.writeShellScriptBin "audio-mic-users" ''
    # Pinned PATH: this script historically relied on the caller's PATH for
    # pactl/awk/find/…, which broke the first non-interactive consumer (the
    # balance daemon's mic duck gate runs under systemd's minimal PATH —
    # every tool errored and the gate fail-opened to "no mic users",
    # 2026-10-05).
    PATH=${pkgs.pulseaudio}/bin:${pkgs.gawk}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:${pkgs.gnugrep}/bin:$PATH
    # --all: also emit the always-on/system captures (as `sys` rows) instead of
    # dropping them. Default output must stay byte-identical to the flagless
    # historical listing, so the flag only ever ADDS rows.
    all=no
    [ "$1" = "--all" ] && all=yes

    # Field separator for the awk→read handoff. Must be NON-whitespace: a tab
    # would be treated as IFS-whitespace and collapse empty fields, shifting
    # columns. 0x1f (unit separator) never appears in the data.
    SEP="$(printf '\037')"

    # Emit one `sys|label|exe|pid` row for an always-on capture ($1 = human
    # label), but only in --all mode. Same trust model as the pw rows: the exe
    # comes from the kernel's /proc/PID/exe, never a client-set string (empty
    # for server-side filter nodes, which have no client process at all).
    sys_row() {
      [ "$all" = yes ] || return 0
      sysexe=""
      [ -n "$pid" ] && sysexe=$(readlink "/proc/$pid/exe" 2>/dev/null)
      printf 'sys|%s|%s|%s\n' "$1" "$sysexe" "$pid"
    }

    # Allowlist of source indices that are GENUINE microphone inputs, resolved
    # from server-side topology by the source's own node name (never a client-
    # set string). A capture is a real mic user ONLY if its Source: index is in
    # here. This is the primary, fail-closed gate: anything not enumerated as a
    # mic source — the sentinel 4294967295 (a --monitor-stream tap on a sink,
    # e.g. the balance daemon's post-leveller readers), any `.monitor`, a
    # monitor of a null/virtual sink, or any not-yet-known plumbing — is simply
    # absent and therefore never counted, without having to be denylisted first.
    #
    # "Genuine mic input" = a real capture device (alsa_input./bluez_input.,
    # excluding the snd_aloop guest-gaming loopback which is playback fed back
    # in) OR one of the internal virtual sources that carries real mic audio and
    # is what normal apps actually capture: the RNNoise source (the denoised
    # default), the mic-blend combiner, the mix/cast-sync `delayed.<mic>`
    # wrappers, and consumed remote mics from the tailnet mesh (tailnet-rmic-).
    mic_sources=$(pactl list sources 2>/dev/null | awk '
      /^Source #/          { idx = substr($2, 2) }
      /^[[:space:]]*Name:/ {
        name = $2
        if (name ~ /\.monitor$/)       next   # any monitor is not a mic
        if (name ~ /platform-snd_aloop/) next  # loopback, played-audio fed back
        ok = 0
        if (name ~ /^alsa_input\./)    ok = 1   # physical capture device
        if (name ~ /^bluez_input\./)   ok = 1   # bluetooth mic
        if (name == "rnnoise_source")  ok = 1   # denoised default source
        if (name == "combined_mics")   ok = 1   # mic-blend combiner
        if (name ~ /^delayed\./)       ok = 1   # mix/cast-sync mic wrappers
        if (name ~ /^tailnet-rmic-/)   ok = 1   # consumed remote mesh mic
        if (ok) print idx
      }
    ' | sort -u)

    is_mic_source() {
      for m in $mic_sources; do [ "$m" = "$1" ] && return 0; done
      return 1
    }

    # Resolve an electron/chromium PID to a real product name (Vesktop, Discord,
    # …) by walking up to the root electron process and reading its cmdline —
    # the same approach the output app mixer uses. Generic electron apps all
    # advertise application.name = "electron", which is useless on its own.
    resolve_electron() {
      local pid=$1 current=$1 last=$1 ppid exe cmdline
      while true; do
        ppid=$(awk '/^PPid:/{print $2}' "/proc/$current/status" 2>/dev/null)
        [ -z "$ppid" ] || [ "$ppid" = "1" ] || [ "$ppid" = "0" ] && break
        exe=$(readlink "/proc/$ppid/exe" 2>/dev/null)
        case "$exe" in
          *electron*|*chromium*) last=$ppid; current=$ppid ;;
          *) break ;;
        esac
      done
      cmdline=$(tr '\0' ' ' < "/proc/$last/cmdline" 2>/dev/null)
      case "$cmdline" in
        *[Vv]esktop*)  echo "Vesktop" ;;
        *[Dd]iscord*)  echo "Discord" ;;
        *[Ss]lack*)    echo "Slack" ;;
        *[Oo]bsidian*) echo "Obsidian" ;;
        *)
          # Extract app name from a nix store path: /nix/store/hash-appname-ver/
          echo "$cmdline" \
            | sed -n 's|.*/nix/store/[^/]*/\([^/ ]*\).*|\1|p' \
            | head -1 \
            | sed 's/-[0-9].*//'
          ;;
      esac
    }

    # "yes" if $1 is the replay-buffer screen recorder's own mic capture. Proven
    # by the systemd-assigned cgroup AND the real executable behind the pid —
    # NEITHER of which a process can forge — rather than the stream's self-
    # reported name/pid. So an app can't dodge the indicator by calling itself
    # "gpu-screen-recorder"; it would need to actually BE the recorder running
    # inside the replay-buffer service.
    is_replay_gsr() {
      p="$1"
      [ -n "$p" ] || return 1
      case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
        *gpu-screen-recorder*) ;;
        *) return 1 ;;
      esac
      case "$(cat "/proc/$p/cgroup" 2>/dev/null)" in
        *replay-buffer.service*) return 0 ;;
      esac
      return 1
    }

    # "yes" if $1 belongs to the voice assistant's user service. Its wake-word
    # recorder captures the mic CONTINUOUSLY by design (same always-listening
    # class as the replay buffer), so it must never read as an app actively
    # using the mic. Proven by the systemd cgroup, which a process can't forge.
    is_assistant() {
      p="$1"
      [ -n "$p" ] || return 1
      case "$(cat "/proc/$p/cgroup" 2>/dev/null)" in
        *voice-assistant.service*) return 0 ;;
      esac
      return 1
    }

    # "yes" if $1 belongs to the balance daemon's user service. Its slot
    # loudness readers capture applvl monitors — playback, never mic — but
    # while the daemon rewires slots a reader's Source transiently reads
    # unattached, which the mic-source allowlist already drops; this is the
    # cgroup-proven belt-and-braces on top.
    # Cgroup-proven, same trust model as is_assistant/is_replay_gsr.
    is_balance() {
      p="$1"
      [ -n "$p" ] || return 1
      case "$(cat "/proc/$p/cgroup" 2>/dev/null)" in
        *audio-balance.service*) return 0 ;;
      esac
      return 1
    }

    # "yes" if $1 is one of the mix-sync daemon's pw-loopback time-align
    # wrappers (sync.<mic> → delayed.<mic>). They capture the raw mics
    # CONTINUOUSLY by design — plumbing, never an app using the mic. Proven
    # by exe + the systemd cgroup, same trust model as the gates above.
    is_micsync() {
      p="$1"
      [ -n "$p" ] || return 1
      case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
        *pw-loopback*) ;;
        *) return 1 ;;
      esac
      case "$(cat "/proc/$p/cgroup" 2>/dev/null)" in
        *audio-mix-sync.service*) return 0 ;;
      esac
      return 1
    }

    # Client index → process id, for capture streams that carry no
    # application.process.id of their own (pw-loopback streams: the pid
    # lives on the CLIENT object, not the stream). Only used as a fallback
    # when the stream props have no pid at all.
    client_pids=$(pactl list clients 2>/dev/null | awk '
      /^Client #/                   { idx = substr($2, 2) }
      /application\.process\.id = / { split($0, a, "\""); print idx, a[2] }
    ')
    client_pid() {
      [ -n "$1" ] && [ "$1" != "n/a" ] || return 0
      printf '%s\n' "$client_pids" | awk -v c="$1" '$1 == c { print $2; exit }'
    }

    {
      # ── PipeWire capture streams ───────────────────────────────────────────
      pactl list source-outputs 2>/dev/null | awk -v SEP="$SEP" '
        function flush() {
          if (id != "")
            print id SEP src SEP corked SEP pid SEP appname SEP medianame SEP nodename SEP client
        }
        /^Source Output #/             { flush(); id=substr($3,2); src=""; corked=""; pid=""; appname=""; medianame=""; nodename=""; client="" }
        /^[[:space:]]*Source:/         { src=$2 }
        /^[[:space:]]*Corked:/         { corked=$2 }
        /^[[:space:]]*Client:/         { client=$2 }
        /application\.process\.id = /  { split($0,a,"\""); pid=a[2] }
        /application\.name = /         { split($0,a,"\""); appname=a[2] }
        /media\.name = /               { split($0,a,"\""); if (medianame=="") medianame=a[2] }
        /node\.name = /                { split($0,a,"\""); nodename=a[2] }
        END { flush() }
      ' | while IFS="$SEP" read -r id src corked pid appname medianame nodename client; do
        [ "$corked" = "yes" ] && continue
        # PRIMARY GATE (fail-closed): count a capture as a mic user ONLY when its
        # Source: index resolves to a genuine mic input in the allowlist above.
        # This drops, without needing to be denylisted:
        #  - `.monitor` sources and null/virtual-sink monitors (playback taps),
        #  - the sentinel Source: 4294967295 — a `parec --monitor-stream=N` tap
        #    bound to a sink-input by index (e.g. the balance daemon's post-
        #    leveller loudness readers). It has no valid source index at all, so
        #    it can never be in the allowlist. Reads PLAYBACK, never a mic.
        #  - Source: n/a (mid-move/reconnect — hearing nothing for that frame),
        #  - any not-yet-known plumbing (a new virtual sink's monitor, etc.).
        # The index and the source's node name are BOTH server-side topology;
        # a real mic capture always resolves to a real capture-device source.
        is_mic_source "$src" || continue
        # The balance daemon's own loudness readers (cgroup-proven) — belt and
        # braces on top of the allowlist gate, since a reader can transiently
        # detach/re-attach while the daemon rewires slots.
        is_balance "$pid" && { sys_row "loudness meter (balance)"; continue; }
        # Our own bar level meter (qs-mic-level) and per-mic VAD taps (qs-vad) —
        # never count them as mic users.
        [ "$appname" = "qs-mic-level" ] && { sys_row "level meter (shell)"; continue; }
        [ "$appname" = "qs-vad" ] && { sys_row "voice detect (shell)"; continue; }
        # The voice assistant's always-on wake-word recorder (cgroup-proven).
        is_assistant "$pid" && { sys_row "voice assistant (wake)"; continue; }
        # The mic filter stack's own passive intake (the echo-cancel capture,
        # which holds the capture.rnnoise_source interface name): a server-side
        # filter node has no Client (a real pulse/pipewire app always does, and
        # can't fake "n/a"), so this can't be spoofed by naming a stream
        # capture.rnnoise_source. The inner rnnoise capture
        # (capture.rnnoise_source.filter) captures aec_source, which is not in
        # the mic-source allowlist, so the primary gate already drops it.
        [ "$nodename" = "capture.rnnoise_source" ] && [ "$client" = "n/a" ] \
          && { sys_row "mic filter (aec+rnnoise)"; continue; }
        # The mic combiner's per-mic capture streams (see combined_mics in
        # flakes/audio/pipewire.nix) — server-side too, same no-Client rule. Prefix
        # match because PipeWire may uniquify duplicate stream node names (the
        # per-mic sys rows are identical and collapse under the final sort -u).
        case "$nodename" in capture.combined_mics*)
          [ "$client" = "n/a" ] && { sys_row "mic blend (combiner)"; continue; } ;;
        esac
        # The mix-sync daemon's delayed.<mic> wrappers (audio-mix-sync): each
        # is a pw-loopback whose capture side is named input.sync.<mic>. One
        # per physical mic, hence the pile of phantoms when unlisted. NB these
        # are NOT server-side: pw-loopback is a real client, so the no-Client
        # rule the blend/filter rows use never matched (found 2026-10-05 —
        # the first cut of this gate required client = n/a and let every sync
        # tap through). Instead the stream's Client resolves to a pid (the
        # pid lives on the client object, not the stream) and the exe+cgroup
        # proof pins it to the actual mix-sync service.
        case "$nodename" in input.sync.*)
          [ "$client" = "n/a" ] && { sys_row "mic mix sync (delay wrapper)"; continue; }
          syncpid=$(client_pid "$client")
          if is_micsync "$syncpid"; then
            pid="$syncpid"
            sys_row "mic mix sync (delay wrapper)"
            continue
          fi ;;
        esac
        # (tailnet-audio donated mics are plain pipe-source nodes with no internal
        # capture stream, so they need no exclusion here — they behave exactly
        # like a hardware mic and are counted in-use only when a real app captures.)
        # The screen recorder's always-on mic capture (replay buffer). It is
        # always listening by design, so it shouldn't read as an app actively
        # using the mic — but only skip it when it's PROVABLY the real recorder
        # (cgroup + exe), so nothing can hide behind its name. gsr names its mic
        # node "gsr-default_input" (a real capture bound to a mic source, so the
        # allowlist keeps it here); its default_output capture is a monitor and
        # is already dropped by the mic-source allowlist above.
        case "$nodename" in gsr-*)
          is_replay_gsr "$pid" && { sys_row "replay buffer (gsr)"; continue; } ;;
        esac
        exe=""
        [ -n "$pid" ] && exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
        name="$appname"
        [ -z "$name" ] && name="$medianame"
        [ -z "$name" ] && name="$nodename"
        [ -z "$name" ] && name="unknown"
        # Generic electron/chromium apps report themselves as "electron" — swap
        # in the resolved product name (e.g. Vesktop) when we can find it.
        case "$exe" in
          *electron*|*chromium*)
            resolved=$(resolve_electron "$pid")
            [ -n "$resolved" ] && name="$resolved" ;;
        esac
        printf 'pw|%s|%s|%s\n' "$name" "$exe" "$pid"
      done

      # ── Raw capture-device holders (direct ALSA, bypassing PipeWire) ───────
      # `find -lname` matches symlink targets in a SINGLE pass. A per-fd
      # $(readlink) loop over every PID is O(thousands of forks) and took
      # 15-40s, which both lagged the indicator and starved the dropdown's
      # 1.5s poll (it got killed/restarted before finishing). Capture device
      # nodes end in 'c' (playback nodes end in 'p').
      find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/snd/pcmC*c' 2>/dev/null \
        | while IFS= read -r fd; do
            pid="''${fd#/proc/}"
            pid="''${pid%%/*}"
            exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
            base="''${exe##*/}"
            # Filter legit holders by their REAL binary (exe), not comm/cmdline.
            case "$base" in
              pipewire|pipewire-pulse|wireplumber|pw-*) continue ;;
            esac
            printf 'raw|%s|%s|%s\n' "''${base:-unknown}" "$exe" "$pid"
          done
    } | sort -u   # collapse an app's multiple streams (e.g. per-source meters)
  '';

  # Reads s16-mono PCM on stdin in 50ms windows and prints one peak-level value
  # per window (0..100, dBFS-mapped over a -50dB floor). Drives the live input
  # meter on the bar mic icon.
  mic-level-pl = pkgs.writeText "qs-mic-level.pl" ''
    use strict; use warnings;
    $| = 1;
    my $rate  = 8000;
    my $win   = int($rate * 0.05);   # 50ms window
    my $bytes = $win * 2;            # s16 mono
    binmode STDIN;
    my $buf = "";
    while (1) {
        my $chunk;
        my $n = read(STDIN, $chunk, $bytes);
        last if !defined($n) || $n == 0;
        $buf .= $chunk;
        while (length($buf) >= $bytes) {
            my $frame = substr($buf, 0, $bytes, "");
            my @s = unpack("s<*", $frame);
            my $peak = 0;
            for my $v (@s) { my $a = $v < 0 ? -$v : $v; $peak = $a if $a > $peak; }
            my $level = 0;
            if ($peak > 0) {
                my $db = 20 * log($peak / 32768) / log(10);
                $level = ($db + 50) / 50 * 100;
                $level = 0   if $level < 0;
                $level = 100 if $level > 100;
            }
            print int($level), "\n";
        }
    }
  '';

  # Streams the live level of an audio device as one 0..100 number per ~50ms on
  # stdout.
  #   $1  parec device  (default @DEFAULT_SOURCE@; use @DEFAULT_MONITOR@ for the
  #                       default sink's output, or a sink/source name)
  #   $2  optional sink-input index to monitor a single app's playback level
  # Capturing @DEFAULT_SOURCE@ reads POST-filter levels when RNNoise is on (i.e.
  # what leaks through). Names itself "qs-mic-level" so the mic-users enumerator
  # drops it (real-source captures would otherwise list themselves as a mic user
  # / trip the in-use indicator; monitor captures are already skipped as
  # monitors).
  level-meter-sh = pkgs.writeShellScriptBin "audio-level-meter" ''
    target="''${1:-@DEFAULT_SOURCE@}"
    monidx="''${2:-}"
    exec parec --rate=8000 --channels=1 --format=s16le --latency-msec=40 \
      -d "$target" ''${monidx:+--monitor-stream="$monidx"} \
      --client-name=qs-mic-level --stream-name=qs-mic-level 2>/dev/null \
      | ${pkgs.perl}/bin/perl ${mic-level-pl}
  '';

  # ── Speech-activity meter (VAD variant of the level meter) ──────────────────
  # Unlike level-meter-sh (raw peak loudness), this classifies whether each frame
  # is *speech* using WebRTC VAD — a tiny C library built for real-time telephony,
  # so it's cheap enough to run one instance per candidate mic continuously. It
  # discriminates voice from steady non-speech noise (fans, keyboard, hum) that
  # a pure energy meter can't, which is what the auto-switch selection needs:
  # "which mic is hearing ME", not "which mic is loudest".
  #
  # Output: one line per ~60ms window — `speech snr level`
  #   speech : 1 if the window is majority-voiced, else 0
  #   snr    : dB of the loudest voiced frame above this mic's tracked noise floor
  #            (the per-mic-comparable number — a near headset reads high, a far
  #            desk mic reads low even at the same absolute loudness)
  #   level  : 0..100 peak of voiced frames, dBFS-mapped over a -50dB floor (0
  #            while not speaking), matching mic-level.pl's scale
  # setuptools: webrtcvad does `import pkg_resources` at import time.
  vad-python = pkgs.python3.withPackages (ps: [
    ps.webrtcvad
    ps.setuptools
  ]);
  vad-meter-py = pkgs.writeText "qs-vad-meter.py" ''
    import signal, sys, struct, math
    import webrtcvad

    # Die quietly when our reader (the daemon) tears the pipeline down —
    # Python's default turns SIGPIPE into a BrokenPipeError traceback that
    # spams the journal on every meter stop.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)

    RATE = 16000                 # WebRTC VAD supports 8/16/32/48k; 16k is the sweet spot
    FRAME_MS = 20                # VAD requires 10/20/30ms frames
    FRAME_SAMPLES = RATE * FRAME_MS // 1000
    FRAME_BYTES = FRAME_SAMPLES * 2          # s16 mono
    GROUP = 3                    # emit one line per GROUP frames (~60ms)
    NF_ALPHA = 0.03              # noise-floor EWMA follow rate (per non-speech frame)
    MINSTAT_SUB = 50             # frames per min-stat sub-window (~1s at 20ms)
    MINSTAT_N = 8                # sub-windows kept (~8s of history)
    FLOOR_DB = -70.0             # dBFS that maps to level 0 — low enough that a dead
                                 # (muted/unplugged) mic reads ~0 while a merely-quiet
                                 # room still reads > 0 (so the daemon can tell them apart)

    # Aggressiveness 0..3 — higher rejects more non-speech as silence. 2 is a good
    # default for distinguishing voice from fan/keyboard without clipping speech.
    agg = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    vad = webrtcvad.Vad(agg)

    # Noise floor in dBFS, tracked from non-speech frames only. Starts conservative
    # so early SNR is sane before it settles to the mic's real floor.
    noise_db = -60.0

    # Minimum-statistics floor over ALL frames (speech-classified or not).
    # WebRTC VAD classifies steady broadband noise (a PC fan right next to a
    # mic) as speech most of the time; with the EWMA floor fed only by
    # non-speech frames it then never learns the fan's level, SNR reads as
    # fan_peak minus a stale -60 floor, and the daemon treats the fan as a
    # person. A fan is CONTINUOUS, so the minimum level over the last ~8s
    # equals the fan level; real speech always has inter-word dips down to
    # the room floor. Taking max(ewma, min_stat) as the effective floor
    # collapses fan "SNR" to ~0 while leaving genuine speech SNR intact.
    minima = []          # completed sub-window minima, newest last
    sub_min = 0.0        # running min of the current sub-window (dBFS <= 0)
    sub_n = 0

    def dbfs(frame):
        n = len(frame) // 2
        if n == 0:
            return -90.0
        samples = struct.unpack("<%dh" % n, frame)
        acc = 0
        for v in samples:
            acc += v * v
        rms = math.sqrt(acc / n)
        if rms < 1.0:
            return -90.0
        return 20.0 * math.log10(rms / 32768.0)

    buf = b""
    voiced = 0
    count = 0
    peak_db = -90.0     # loudest VOICED frame this window (for snr)
    win_peak = -90.0    # loudest frame of ANY kind this window (for level)

    while True:
        chunk = sys.stdin.buffer.read(FRAME_BYTES)
        if not chunk:
            break
        buf += chunk
        while len(buf) >= FRAME_BYTES:
            frame = buf[:FRAME_BYTES]
            buf = buf[FRAME_BYTES:]
            try:
                speech = vad.is_speech(frame, RATE)
            except Exception:
                speech = False
            db = dbfs(frame)
            if db > win_peak:
                win_peak = db
            if sub_n == 0 or db < sub_min:
                sub_min = db
            sub_n += 1
            if sub_n >= MINSTAT_SUB:
                minima.append(sub_min)
                if len(minima) > MINSTAT_N:
                    minima.pop(0)
                sub_n = 0
            if speech:
                voiced += 1
                if db > peak_db:
                    peak_db = db
            else:
                noise_db = (1.0 - NF_ALPHA) * noise_db + NF_ALPHA * db
            count += 1
            if count >= GROUP:
                is_speech = 1 if voiced * 2 >= count else 0
                # level = the window's REAL loudness (any frame), reported always so
                # the daemon can spot a dead/muted mic. snr stays voiced-only — the
                # selection signal — and is 0 on non-speech windows as before.
                level = (win_peak - FLOOR_DB) / (-FLOOR_DB) * 100.0
                level = max(0.0, min(100.0, level))
                floor = noise_db
                stat = minima + ([sub_min] if sub_n else [])
                if stat:
                    floor = max(floor, min(stat))
                snr = max(0.0, peak_db - floor) if is_speech else 0.0
                sys.stdout.write("%d %d %d\n" % (is_speech, int(snr), int(level)))
                sys.stdout.flush()
                voiced = 0
                count = 0
                peak_db = -90.0
                win_peak = -90.0
  '';

  # Streams speech-activity of a device as `speech snr level` per ~60ms. Mirrors
  # level-meter-sh's parec wiring at 16kHz (VAD's native rate). Names itself
  # "qs-vad" so the mic-users enumerator drops it (these taps read real mics and
  # would otherwise each list as a mic user / trip the in-use indicator).
  #
  # The stream must stay pinned to ITS mic, or die trying: without these props,
  # a device re-enumeration (Arctis dongle sleep/wake, USB replug) makes
  # WirePlumber move the orphaned stream to the default source — rnnoise_source
  # — and because every qs-vad stream shares one stream-restore key
  # (by-application-name), that migrated target then gets saved and applied to
  # ALL qs-vad streams. Every meter ends up listening to the active mic, so the
  # daemon can never hear speech on any other candidate and never switches.
  #   node.dont-reconnect    — kill the stream when its device vanishes instead
  #                            of migrating it (the daemon revives it on the
  #                            device's return)
  #   state.restore-target   — never save/apply a stream-restore target for
  #                            these streams (also neutralises any previously
  #                            poisoned saved entry)
  #   $1  parec device (default @DEFAULT_SOURCE@; pass a source name per mic)
  #   $2  optional VAD aggressiveness 0..3 (default 2)
  vad-meter-sh = pkgs.writeShellScriptBin "audio-vad-meter" ''
    target="''${1:-@DEFAULT_SOURCE@}"
    agg="''${2:-2}"
    exec ${pkgs.pulseaudio}/bin/parec --rate=16000 --channels=1 --format=s16le --latency-msec=20 \
      -d "$target" \
      --client-name=qs-vad --stream-name=qs-vad \
      --property=node.dont-reconnect=true \
      --property=state.restore-target=false 2>/dev/null \
      | PYTHONWARNINGS=ignore::UserWarning ${vad-python}/bin/python ${vad-meter-py} "$agg"
  '';

  # ── Auto-switch daemon ──────────────────────────────────────────────────────
  # Watches a config file listing prioritised candidate mics. While auto-switch
  # is enabled AND there are >=2 candidates, it runs one VAD meter per candidate
  # and routes the active mic to whichever is currently *viable* (hearing real
  # speech), preferring higher-priority mics. Crucially it switches ONLY when a
  # candidate shows viable speech — never merely because the current mic went
  # quiet — and holds the current mic when nothing is viable. With <2 candidates
  # or disabled, it spawns nothing (no meters, ~1 stat/sec idle) so it costs
  # nothing when no secondary mics are configured.
  #
  # While live it also mirrors the primary mic's SET capture-volume % (averaged
  # across its channels) onto the other candidates, so the group behaves as one
  # logical mic volume-wise. That is a settings copy driven by pactl subscribe
  # change events — NOT loudness measurement/AGC (a previous AGC was reverted).
  #
  # Routing reuses the existing rnnoise plumbing: when the noise-cancel virtual
  # source is the default (denoise on), it retargets capture.rnnoise_source for a
  # seamless swap; otherwise (denoise off) it sets the default source directly.
  # So auto-switch works whether or not denoising is on.
  #
  # An echo guard makes it deaf to the room's own playback: remote voices out
  # of the speakers are real speech to every mic, so while a VAD meter on the
  # default sink's monitor hears speech, selection holds the current mic
  # (except the dead-mic failover). See "echo_guard" in DEFAULTS.
  #
  # Config: $XDG_CONFIG_HOME/auto-mic/config.json (auto-created, disabled):
  #   { "enabled": true,
  #     "candidates": ["alsa_input.usb-Blue...", "alsa_input.usb-SteelSeries..."],
  #     "snr_min": 6, "viable_ms": 180, "grace_ms": 150, "hysteresis_ms": 350 }
  # candidates are source node.names, highest priority first. "mix_suspended"
  # is daemon/MIX bookkeeping (see audio-auto-mic-mutate suspend/resume).
  auto-mic-daemon-py = pkgs.writeText "auto-mic-daemon.py" ''
    import json, os, signal, subprocess, threading, time

    CONFIG = os.environ.get("AUTO_MIC_CONFIG") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "auto-mic", "config.json")
    STATE  = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "auto-mic-active")
    # Filter on/off, written by qs-rnnoise-toggle. The filter-chain boots ON.
    FILTER_STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "qs-rnnoise-on")
    VAD_METER = os.environ.get("AUTO_MIC_VAD_METER") or "qs-vad-meter"
    SET_INPUT = os.environ.get("AUTO_MIC_SET_INPUT") or "qs-rnnoise-set-input"
    GET_INPUT = os.environ.get("AUTO_MIC_GET_INPUT") or "qs-rnnoise-current-input"
    RN_SOURCE = "rnnoise_source"
    RN_CAP_PORT = "capture.rnnoise_source:input_MONO"   # the filter's mono input port

    DEFAULTS = {
        "enabled": False,
        "candidates": [],      # source node.names, highest priority first
        "snr_min": 6.0,        # dB above the mic's noise floor to count as hearing you at all
        "near_snr": 10.0,      # dB that means you're CLOSE to a mic. We prefer the
                               # highest-priority mic that hears you this clearly; we
                               # leave it for a secondary once it drops below this
                               # (you've walked away) — not at near-silence, so you
                               # don't fade out before the handoff. Close speech ~20-26.
        "stick_db": 2.0,       # the current mic stays "near" with this much lower a bar,
                               # widening the boundary so it can't flap at the threshold
        "viable_ms": 180,      # voicing must persist this long before a mic is viable
        "grace_ms": 150,       # bridge VAD flicker: shorter gaps don't end a voice run
        "hysteresis_ms": 200,  # higher-priority mic must hold this long before we switch UP
                               # (kept short: "back to the priority mic ASAP")
        "drop_ms": 700,        # walk-away condition must hold this long before falling DOWN
                               # (long enough that a brief breath/blip into the close
                               # headset mic while you're quiet won't trigger a switch)
        "settle_ms": 400,      # lockout after any switch, so it can't bounce straight back
        "flap_window_ms": 4000, # switching BACK to a mic we left this recently is a flap...
        "flap_hold_ms": 1500,  # ...and must hold this long first, so borderline SNR at the
                               # near_snr boundary can't ping-pong between two live mics
        "dead_level": 4.0,     # window loudness (0..100) below this = no real signal
        "dead_hold_ms": 150,   # ...sustained this long marks the current mic dead
        "dead_cut_ms": 150,    # then cut away this fast (vs drop_ms for a walk-away),
                               # for when a mic is muted/unplugged and another hears you
        "vad_agg": 3,          # WebRTC VAD aggressiveness 0..3 (3 = reject non-speech hardest)
        "echo_guard": True,    # suppress switching while the default OUTPUT is carrying
                               # speech: remote voices played through speakers reach the
                               # mics as perfectly valid speech (a Discord call pulled the
                               # selection off the mic actually in use — seen live
                               # 2026-10-05). One VAD meter on the default sink's monitor
                               # is the playback reference; candidate speech that overlaps
                               # it cannot be trusted to be the user, so selection holds
                               # the current mic until the playback goes quiet. The DEAD
                               # cut bypasses this (a muted mic must still fail over).
        "echo_clear_ms": 400,  # playback must have been speech-free this long before
                               # switches are considered again (covers the acoustic +
                               # buffering lag between monitor and room)
        "echo_guard_agg": 2,   # VAD aggressiveness for the reference meter (the monitor
                               # is a clean digital signal; 2 catches sung/processed voice
                               # that 3 would reject)
        "crossfade": True,     # make-before-break linking so no audio is lost at a switch
                               # (denoise-on path only; harmless to leave on)
        "crossfade_ms": 120,   # overlap window where both mics feed the filter at once
        "poll_ms": 50,         # selection tick while metering
    }

    def log(*a):
        print("[auto-mic]", *a, flush=True)

    def load_config():
        cfg = dict(DEFAULTS)
        try:
            with open(CONFIG) as f:
                user = json.load(f)
            if isinstance(user, dict):
                cfg.update(user)
        except FileNotFoundError:
            pass
        except Exception as e:
            log("config parse error, using defaults:", e)
        return cfg

    def ensure_config():
        if os.path.exists(CONFIG):
            return
        try:
            os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
            with open(CONFIG, "w") as f:
                json.dump({"enabled": False, "candidates": []}, f, indent=2)
            log("wrote default disabled config at", CONFIG)
        except Exception as e:
            log("could not write default config:", e)

    def default_source():
        try:
            return subprocess.run(["pactl", "get-default-source"],
                                  capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            return ""

    def default_sink():
        try:
            return subprocess.run(["pactl", "get-default-sink"],
                                  capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            return ""

    def sink_is_headphones(name):
        """Same classification rule as the AEC auto daemon: only sinks we
        positively KNOW are worn audio (headphone/headset wording or bluez)
        count; everything else is treated as room speakers."""
        if not name:
            return False
        try:
            out = subprocess.run(["pactl", "list", "sinks"],
                                 capture_output=True, text=True, timeout=5).stdout
        except Exception:
            return False
        blk, hay = False, [name]
        for line in out.splitlines():
            if line.startswith("\tName:"):
                blk = line.split(":", 1)[1].strip() == name
            elif blk and ("Description:" in line or "Active Port:" in line
                          or "device.form_factor" in line):
                hay.append(line)
        import re as _re
        return bool(_re.search(r"headphone|headset|bluez", " ".join(hay), _re.I))

    def set_default(name):
        try:
            subprocess.run(["pactl", "set-default-source", name], timeout=5)
        except Exception:
            pass

    def real_sources():
        """Real (non-monitor, non-virtual) capture sources, by node.name."""
        try:
            out = subprocess.run(["pactl", "list", "short", "sources"],
                                 capture_output=True, text=True, timeout=5).stdout
        except Exception:
            return []
        cand = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                n = parts[1]
                # Site EXTRA on top of the canonical filter: ALL tailnet-*
                # sources — donated phone mics included — are excluded as VAD
                # candidates, because auto-mic must never yank the default
                # onto a network mic on its own.
                if not n.startswith("tailnet-"):
                    cand.append(n)
        # The canonical internal-node filter (internal_node() in the shared
        # audio-naming-awk, exposed as the audio-internal-node bin): monitors,
        # rnnoise/combined virtuals, delay wrappers, loopbacks, snd_aloop...
        # On a (should-never-happen) helper failure return NO candidates
        # rather than unfiltered ones — selecting plumbing would be worse
        # than briefly standing still.
        try:
            r = subprocess.run(["${internal-node-sh}/bin/audio-internal-node"],
                               input="\n".join(cand), capture_output=True,
                               text=True, timeout=5)
            return [n for n in r.stdout.splitlines() if n]
        except Exception:
            return []

    # Average SET volume % of a source across its channels (pactl reports a
    # per-channel %), or None if the source is absent/unreadable. This reads
    # the configured volume setting only — never measured audio levels.
    def source_avg_volume(name):
        try:
            out = subprocess.run(["pactl", "get-source-volume", name],
                                 capture_output=True, text=True, timeout=5).stdout
        except Exception:
            return None
        vols = []
        for tok in out.replace(",", " ").split():
            if tok.endswith("%"):
                try:
                    vols.append(float(tok[:-1]))
                except ValueError:
                    pass
        return (sum(vols) / len(vols)) if vols else None

    class Meter:
        """One VAD meter subprocess per mic; a thread folds its `speech snr level`
        lines into a live voice-run estimate."""
        def __init__(self, mic, cfg, on_line):
            self.mic = mic
            self.grace_s = cfg["grace_ms"] / 1000.0
            self.dead_level = cfg["dead_level"]
            self.on_line = on_line   # called (event-driven) after each window
            self.lock = threading.Lock()
            self.snr = 0.0
            self.level = 100.0       # last window loudness (0..100); ~0 = dead/muted
            self.last_line = 0.0     # monotonic of the last meter line (any kind)
            self.dead_since = None   # monotonic the level first went ~0, else None
            self.last_voiced = 0.0   # monotonic of the last speech==1 window
            self.voice_start = 0.0   # monotonic the current voice run began
            self.snr_ewma = 0.0      # decaying RECENT snr (tracks you getting
                                     # quieter mid-sentence as you walk away — a
                                     # peak-hold would stay stuck at the loud start)
            # New session so we can kill the whole parec|python pipeline cleanly.
            self.proc = subprocess.Popen([VAD_METER, mic, str(cfg["vad_agg"])],
                                         stdout=subprocess.PIPE,
                                         text=True, start_new_session=True)
            self.thread = threading.Thread(target=self._read, daemon=True)
            self.thread.start()

        def _read(self):
            for line in self.proc.stdout:
                parts = line.split()
                if len(parts) != 3:
                    continue
                try:
                    sp, snr, level = int(parts[0]), float(parts[1]), float(parts[2])
                except ValueError:
                    continue
                now = time.monotonic()
                with self.lock:
                    # Track loudness on EVERY window (incl. non-speech) so we can
                    # tell a dead/muted mic (level ~0) from a quiet room.
                    self.level = level
                    self.last_line = now
                    if level < self.dead_level:
                        if self.dead_since is None:
                            self.dead_since = now
                    else:
                        self.dead_since = None
                    if sp:
                        if (now - self.last_voiced) > self.grace_s:
                            self.voice_start = now      # start of a fresh voice run
                            self.snr_ewma = snr
                        else:
                            self.snr_ewma = 0.5 * snr + 0.5 * self.snr_ewma
                        self.last_voiced = now
                        self.snr = snr
                if sp:
                    # Speech window -> re-evaluate selection (driven by the audio
                    # stream, not a clock).
                    try:
                        self.on_line()
                    except Exception:
                        pass

        def viable(self, now, snr_min, viable_ms):
            with self.lock:
                if (now - self.last_voiced) > self.grace_s:
                    return False
                if self.snr_ewma < snr_min:
                    return False
                return (now - self.voice_start) * 1000.0 >= viable_ms

        # The meter pipeline exits when its device vanishes (node.dont-reconnect)
        # — by design, so it can't silently migrate to another source. A dead
        # meter is respawned by _sync_meters on the next node event.
        def alive(self):
            return self.proc.poll() is None

        # True if this mic has been producing essentially no signal (muted /
        # unplugged / dead) for at least hold_ms — distinct from a merely quiet room.
        def is_dead(self, now, hold_ms):
            with self.lock:
                if (now - self.last_line) > 0.5:     # meter stalled: can't tell
                    return False
                return (self.dead_since is not None
                        and (now - self.dead_since) * 1000.0 >= hold_ms)

        def stop(self):
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    self.proc.terminate()
                except Exception:
                    pass

    class Controller:
        def __init__(self):
            self.cfg = load_config()
            self.meters = {}        # mic -> Meter (only while auto-switching)
            self.ref_meter = None   # playback-reference meter (echo guard)
            self.ref_sink = None    # sink whose monitor the ref meter taps
            self.active_mic = None  # real mic currently feeding the filter
            self.pending = None
            self.pending_since = 0.0
            self.last_switch = 0.0
            self.left_at = {}       # mic -> monotonic when we last switched AWAY from it
            self.verify_at = 0.0    # last belief-vs-reality feed check
            self.verify_timer = None  # debounce for node-lifecycle feed checks
            self.volsync_timer = None # debounce for follower volume sync
            self.mix_active = False   # blend feeding the filter -> stand down
            self.mix_check_at = 0.0
            self.lock = threading.RLock()
            self.reload = threading.Event()   # set by SIGHUP (config / filter change)

        # ── state ────────────────────────────────────────────────────────
        def filter_on(self):
            try:
                with open(FILTER_STATE) as f:
                    return f.read().strip() != "off"
            except Exception:
                return True               # the filter-chain boots ON
        def auto_on(self):
            return bool(self.cfg.get("enabled"))
        # MIX mode: the blend (combined_mics) feeds the filter, so per-mic
        # switching is meaningless and the daemon must stand down — routing
        # "back" to a single mic here is exactly the fight that both killed
        # the MIX toggle instantly and left a raw mic linked ALONGSIDE the
        # combiner (audible echo once the sync wrappers added real delay).
        # Read the INTENT (target.object metadata) — not the live links,
        # which lag during the retarget and made this racy.
        def mix_on(self):
            try:
                out = subprocess.run([GET_INPUT], capture_output=True,
                                     text=True, timeout=5).stdout.strip()
                return out == "combined_mics"
            except Exception:
                return self._current_feed() == "combined_mics"
        def system_active(self):
            # We pin rnnoise_source as the default and manage routing whenever
            # EITHER the filter or auto-switch is on. With BOTH off we step aside
            # entirely so the menu drives real devices directly (escape hatch).
            return self.auto_on() or self.filter_on()
        def _candidates(self):
            return self.cfg.get("candidates") or []

        def ensure_default_rnnoise(self):
            if default_source() != RN_SOURCE:
                set_default(RN_SOURCE)

        def _set_active(self, mic):
            self.active_mic = mic
            try:
                with open(STATE, "w") as f:
                    f.write((mic or "") + "\n")
            except Exception:
                pass

        # One VAD meter per candidate, but ONLY while auto-switching is on,
        # and ONLY for devices that are actually present: node.dont-reconnect
        # stops a stream migrating when its device vanishes, but at CREATION
        # pipewire-pulse still falls back to the default source — a meter
        # spawned for an unplugged mic silently listens to rnnoise_source,
        # reports the active mic's speech as its own, and the daemon flaps
        # the live mic mid-sentence (seen live: two ghost meters for absent
        # mics made calls unusable). Node add events re-run this, so a mic
        # gets its meter the moment it appears. Also revives dead meters
        # (a meter dies with its device, by design).
        def _sync_meters(self):
            want = (set(self._candidates()) & set(real_sources())
                    if (self.auto_on() and len(self._candidates()) >= 2) else set())
            for mic in list(self.meters):
                if mic not in want or not self.meters[mic].alive():
                    self.meters.pop(mic).stop()
            for mic in want:
                if mic not in self.meters:
                    self.meters[mic] = Meter(mic, self.cfg, self.on_meter_update)
            # Echo guard: one meter on the default sink's monitor — the
            # playback reference. Follows the default sink (respawned here on
            # every node/server event via _schedule_verify) and lives only
            # while candidate meters do, so it costs nothing when auto is off.
            sink = default_sink() if (want and self.cfg.get("echo_guard", True)) else ""
            # Headphone-class output: no acoustic path from playback to the
            # room mics (and the Arctis earcups measurably don't even reach
            # their own boom mic), so a guard here only does harm — audio
            # playing in the user's EARS froze all switching, and walking
            # away while listening never handed off (2026-10-06). Guard only
            # when the room can hear the playback, same classification as
            # the AEC auto daemon.
            if sink and sink_is_headphones(sink):
                sink = ""
            if self.ref_meter is not None and (
                    not sink or self.ref_sink != sink or not self.ref_meter.alive()):
                self.ref_meter.stop()
                self.ref_meter = None
                self.ref_sink = None
            if sink and self.ref_meter is None:
                rcfg = dict(self.cfg)
                rcfg["vad_agg"] = int(self.cfg.get("echo_guard_agg", 2))
                # No selection callback: playback windows must never drive a
                # selection tick, only taint coincident candidate speech.
                self.ref_meter = Meter(sink + ".monitor", rcfg, lambda: None)
                self.ref_sink = sink

        def route(self, mic):
            # Always send the chosen mic THROUGH the filter (make-before-break
            # crossfade); never swap the default to a raw device.
            try:
                if self.cfg.get("crossfade", True):
                    self._crossfade_to(mic)
                else:
                    subprocess.run([SET_INPUT, mic], timeout=5)
            except Exception as e:
                log("route failed:", e)
            self._set_active(mic)

        # Make-before-break: link the new mic into the rnnoise capture BEFORE
        # dropping the old one, so the stream never goes silent (a hard retarget
        # leaves a gap that clips words mid-sentence). Both mics feed the filter
        # for crossfade_ms — a brief, unnoticeable overlap, far better than a gap.
        def _crossfade_to(self, mic):
            newport = self._first_out_port(mic)
            if not newport:
                subprocess.run([SET_INPUT, mic], timeout=5)   # fallback: hard retarget
                return
            # 1. make: add the new link while the old one is still carrying audio.
            subprocess.run(["pw-link", newport, RN_CAP_PORT], timeout=5,
                           stderr=subprocess.DEVNULL)
            # 2. overlap so there is never a silent moment.
            time.sleep(self.cfg.get("crossfade_ms", 120) / 1000.0)
            # 3. point the filter's metadata at the new mic so WirePlumber won't
            #    re-create the old link, and the UI resolves the right device.
            subprocess.run([SET_INPUT, mic], timeout=5)
            # 4. break: drop every other source still feeding the capture.
            for srcport in self._links_into(RN_CAP_PORT):
                if srcport != newport:
                    subprocess.run(["pw-link", "-d", srcport, RN_CAP_PORT],
                                   timeout=5, stderr=subprocess.DEVNULL)

        # The first output (capture) port of a source node, e.g.
        # "alsa_input.…Yeti…:capture_AUX0" or "…Arctis…:capture_MONO".
        def _first_out_port(self, mic):
            try:
                out = subprocess.run(["pw-link", "-o"], capture_output=True,
                                     text=True, timeout=5).stdout
            except Exception:
                return None
            pref = mic + ":"
            for line in out.splitlines():
                s = line.strip()
                if s.startswith(pref):
                    return s
            return None

        # Source ports currently linked into the given input port.
        def _links_into(self, port):
            try:
                out = subprocess.run(["pw-link", "-l"], capture_output=True,
                                     text=True, timeout=5).stdout
            except Exception:
                return []
            res = []
            inblock = False
            for line in out.splitlines():
                if line[:1] not in (" ", "\t"):
                    inblock = (line.strip() == port)
                    continue
                if inblock and "|<-" in line:
                    res.append(line.split("|<-", 1)[1].strip())
            return res

        # Node name of the mic currently feeding the filter (or None).
        def _current_feed(self):
            for srcport in self._links_into(RN_CAP_PORT):
                return srcport.rsplit(":", 1)[0]
            return None

        # ── selection — runs on each VAD window (driven by the audio stream) ──
        def on_meter_update(self):
            if not self.auto_on():
                return
            with self.lock:
                self._select()

        def _select(self):
            now = time.monotonic()
            cfg = self.cfg
            # Rate-limited MIX check (an exec per speech window would be
            # heavy): while the blend feeds the filter, no selection at all.
            if (now - self.mix_check_at) >= 2.0:
                self.mix_check_at = now
                self.mix_active = self.mix_on()
            if self.mix_active:
                self.pending = None
                return
            # Echo guard: while the playback reference carries (recent) speech,
            # any speech the candidates hear may just be the speakers — remote
            # voices register as fully viable speech on every mic and yanked
            # the selection off the mic actually in use. Hold the current mic;
            # selection resumes echo_clear_ms after the playback goes quiet.
            # A DEAD active mic bypasses the guard: muted/unplugged means the
            # user is silent to everyone, and failing over beats staying deaf.
            active_dead = (self.active_mic in self.meters
                           and self.meters[self.active_mic].is_dead(
                               now, cfg["dead_hold_ms"]))
            if (self.ref_meter is not None and not active_dead
                    and (now - self.ref_meter.last_voiced) * 1000.0
                        < cfg.get("echo_clear_ms", 400)):
                self.pending = None
                return
            cands = self._candidates()

            def is_viable(m, snr):
                return (m in self.meters
                        and self.meters[m].viable(now, snr, cfg["viable_ms"]))

            # "near" = you're CLOSE to a mic; the current one gets a lower bar
            # (stick_db) so it can't flap at the threshold.
            def is_near(m):
                bar = cfg["near_snr"] - (cfg["stick_db"] if m == self.active_mic else 0.0)
                return is_viable(m, bar)

            # Prefer the highest-priority mic you're close to; hand off as soon as
            # it drops below near_snr (walked away) while still audible. Fall back
            # to any mic that hears you so you stay live.
            desired = next((m for m in cands if is_near(m)), None)
            if desired is None:
                desired = next((m for m in cands if is_viable(m, cfg["snr_min"])), None)
            if desired is None:
                self.pending = None
                return
            if desired == self.active_mic:
                self.pending = None
                # Belief-vs-reality check: WirePlumber can re-link the filter
                # behind our back (boot race, device hotplug), leaving us
                # convinced the desired mic is live while another — possibly
                # muted — one actually feeds the capture. Rate-limited so the
                # pw-link exec cost stays negligible; still event-driven (only
                # runs on speech windows — verify_feed covers the silent-feed
                # case where no speech window can ever fire).
                if (now - self.verify_at) >= 2.0:
                    self.verify_at = now
                    if self._current_feed() != desired:
                        self.ensure_default_rnnoise()
                        self.route(desired)
                        self.last_switch = now
                        log("re-route (feed drifted) ->", desired)
                return

            ai = cands.index(self.active_mic) if self.active_mic in cands else len(cands)
            di = cands.index(desired)
            threshold = cfg["hysteresis_ms"] if di < ai else cfg["drop_ms"]
            # Anti-flap: switching BACK to a mic we only just left needs a much
            # longer hold — with two live mics at borderline distance the near
            # test oscillates around near_snr, and without this the daemon
            # ping-pongs between them every settle window.
            left = self.left_at.get(desired)
            if left is not None and (now - left) * 1000.0 < cfg["flap_window_ms"]:
                threshold = max(threshold, cfg["flap_hold_ms"])
            # If the current mic has gone entirely dead (muted/unplugged) while
            # another is hearing you, cut across fast instead of waiting out the
            # normal walk-away delay (overrides the flap hold: a dead mic means
            # silence, so getting audible again beats damping the ping-pong).
            if active_dead:
                threshold = cfg["dead_cut_ms"]
            if (now - self.last_switch) * 1000.0 < cfg["settle_ms"]:
                return
            if self.pending != desired:
                self.pending = desired
                self.pending_since = now
            elif (now - self.pending_since) * 1000.0 >= threshold:
                self.ensure_default_rnnoise()
                if self.active_mic:
                    self.left_at[self.active_mic] = now
                self.route(desired)
                self.pending = None
                self.last_switch = now
                log("switch ->", desired)

        # ── state machine — run on start, on SIGHUP, on default-change ────
        def apply_state(self):
            with self.lock:
                self.cfg = load_config()
                if self.system_active():
                    # Carry the real mic we were on into the filter input, then pin
                    # rnnoise_source as the one default everything lives behind.
                    d = default_source()
                    if d and d != RN_SOURCE and d in real_sources():
                        subprocess.run([SET_INPUT, d], timeout=5)
                    self.ensure_default_rnnoise()
                    self._sync_meters()
                    feed = self._current_feed()
                    self.mix_active = self.mix_on()
                    if self.mix_active:
                        pass        # MIX owns the feed; keep active_mic as-is
                    elif not self.auto_on():
                        self._set_active(feed)
                    else:
                        cands = self._candidates()
                        target = (self.active_mic if self.active_mic in cands
                                  else feed if feed in cands
                                  else (cands[0] if cands else None))
                        # Enforce, don't just record: at boot the filter's links
                        # may not exist yet (feed None) and WirePlumber can later
                        # restore them to a different mic than the one we picked.
                        # Routing here makes belief and reality match on every
                        # start/SIGHUP; the feed-drift check in _select self-heals
                        # any later divergence.
                        if target and feed != target:
                            log("route (apply_state) ->", target)
                            self.route(target)
                        else:
                            self._set_active(target)
                else:
                    # Both off: step aside — drop meters, hand the default back to a
                    # real device so the menu drives hardware directly.
                    self._sync_meters()           # auto off -> clears all meters
                    feed = self._current_feed()
                    if feed and feed in real_sources():
                        set_default(feed)
                    self.pending = None
                    self._set_active(None)
                log("state: active=%s auto=%s filter=%s mic=%s"
                    % (self.system_active(), self.auto_on(), self.filter_on(), self.active_mic))
                # Converge follower volumes on start / enable / config edits
                # (the handler no-ops when auto is off or <2 candidates).
                self._schedule_volsync()

        # ── node-lifecycle feed check ─────────────────────────────────────
        # The feed-drift check in _select only runs on speech windows, so it
        # is deaf to the failure it exists to repair when the feed itself is
        # the break: a mis-linked feed means rnnoise outputs silence, the
        # meters hear silence, no speech window ever fires, and the check
        # never runs (boot race: WirePlumber links the filter's capture
        # before the USB mic's node exists, then never revisits). This check
        # runs on source add/remove events instead — no audio required.
        def verify_feed(self):
            with self.lock:
                if not self.system_active():
                    return
                self.mix_active = self.mix_on()
                if self.mix_active:
                    return          # blend is the intended feed; hands off
                feed = self._current_feed()
                cands = self._candidates()
                target = self.active_mic
                if self.auto_on() and target not in cands:
                    target = cands[0] if cands else None
                if not target or feed == target:
                    return
                if not self._first_out_port(target):
                    return          # node not up yet; the next add event retries
                self.ensure_default_rnnoise()
                self.route(target)
                self.last_switch = time.monotonic()
                log("re-route (node event) ->", target)

        # Node event settled: revive any meters that died with their device,
        # then make feed belief match reality.
        def _on_node_event(self):
            with self.lock:
                self._sync_meters()
            self.verify_feed()

        def _schedule_verify(self):
            # Coalesce the event burst a device add/remove emits, and give a
            # fresh node a moment to expose its ports before checking. One-shot
            # timer armed per event — still event-driven, no clock polling.
            with self.lock:
                if self.verify_timer is not None:
                    self.verify_timer.cancel()
                self.verify_timer = threading.Timer(0.5, self._on_node_event)
                self.verify_timer.daemon = True
                self.verify_timer.start()

        # ── follower volume sync (settings copy — deliberately NOT AGC) ───
        # While auto-switch is live the candidate set acts as one logical mic,
        # so the SET capture volume follows too: the primary mic's configured
        # volume % (averaged across its channels) is copied to every other
        # candidate. Pure settings mirroring off pactl subscribe change
        # events; no measured loudness ever feeds back into a volume (a
        # previous AGC implementation was explicitly reverted).
        # Primary = the mic currently feeding the filter (active_mic): that is
        # the one the user hears and adjusts, which beats "highest-priority
        # candidate" when the two differ (walked away to a secondary). Falls
        # back to the top-priority candidate before the first route settles.
        def _sync_volumes(self):
            with self.lock:
                cands = self._candidates()
                if not self.auto_on() or len(cands) < 2:
                    return
                primary = (self.active_mic if self.active_mic in cands
                           else cands[0])
            avg = source_avg_volume(primary)
            if avg is None:
                return       # primary absent/unreadable: leave followers be
            target = int(round(avg))
            for mic in cands:
                if mic == primary:
                    continue
                cur = source_avg_volume(mic)
                # Compare-before-set is the event-loop guard: our own
                # set-source-volume fires more change events, but on that
                # pass every follower already reads back equal to target,
                # nothing differs by >=1%, and no further sets happen —
                # idempotent, converges in one extra (silent) pass.
                if cur is None or abs(cur - target) < 1.0:
                    continue
                try:
                    subprocess.run(["pactl", "set-source-volume", mic,
                                    "%d%%" % target], timeout=5)
                    log("volume follow:", mic, "-> %d%%" % target,
                        "(primary", primary + ")")
                except Exception:
                    pass

        def _schedule_volsync(self):
            # Coalesce the burst of change events one volume drag emits (same
            # one-shot-timer debounce as _schedule_verify — armed per event,
            # no clock polling).
            with self.lock:
                if self.volsync_timer is not None:
                    self.volsync_timer.cancel()
                self.volsync_timer = threading.Timer(0.3, self._sync_volumes)
                self.volsync_timer.daemon = True
                self.volsync_timer.start()

        # ── default-change + node events (pactl subscribe; no polling) ────
        def watch_default(self):
            try:
                proc = subprocess.Popen(["pactl", "subscribe"],
                                        stdout=subprocess.PIPE, text=True)
            except Exception as e:
                log("subscribe failed:", e)
                return
            for line in proc.stdout:
                if "on server" in line:          # default sink/source changed
                    with self.lock:
                        if self.system_active():
                            self.ensure_default_rnnoise()
                    # A default-SINK change moves the playback reference —
                    # the debounced node handler re-resolves the ref meter.
                    self._schedule_verify()
                elif " on source #" in line and ("'new'" in line or "'remove'" in line):
                    # NB: " on source #" — a bare " on source" also matches
                    # "on source-output", i.e. every app stream open/close.
                    self._schedule_verify()      # device appeared/vanished
                elif " on source #" in line and "'change'" in line:
                    # A source property changed — likely a volume set. pactl
                    # subscribe names neither the property nor the node, so
                    # the debounced handler just re-reads and no-ops when the
                    # volumes already agree (also the self-event guard).
                    self._schedule_volsync()

        def reload_loop(self):
            while True:
                self.reload.wait()
                self.reload.clear()
                self.apply_state()

        # ── stale MIX-suspension heal (startup only) ──────────────────────
        # MIX suspends auto-switch via config (enabled=false, mix_suspended=
        # true; see audio-auto-mic-mutate suspend/resume). The matching
        # resume runs when MIX is turned OFF — but a reboot/crash tears MIX
        # down without one, which would leave auto-switch silently disabled
        # forever (exactly how it was lost for days in 2026-10). On startup,
        # a suspension with no live blend is stale: resume it. One-shot and
        # deliberately delayed so the graph (and any genuinely restored MIX
        # routing) is up before we judge; NOT run on SIGHUP — during a MIX
        # enable the suspend flags land before the blend routing does, and
        # healing in that window would re-enable auto mid-transition.
        def heal_suspend(self):
            try:
                cfg = load_config()
                if not cfg.get("mix_suspended"):
                    return
                if self.mix_on() or default_source() == "combined_mics":
                    return          # MIX really is active; suspension stands
                try:
                    with open(CONFIG) as f:
                        raw = json.load(f)
                except Exception:
                    raw = {}
                raw["enabled"] = True
                raw["mix_suspended"] = False
                tmp = CONFIG + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(raw, f, indent=2)
                os.replace(tmp, CONFIG)
                log("resumed auto-switch (stale MIX suspension after restart)")
                self.reload.set()
            except Exception as e:
                log("suspend heal failed:", e)

        def run(self):
            ensure_config()
            log("started; config", CONFIG)
            self.apply_state()
            threading.Thread(target=self.reload_loop, daemon=True).start()
            self._schedule_verify()   # cover nodes that appear before subscribe attaches
            t = threading.Timer(3.0, self.heal_suspend)
            t.daemon = True
            t.start()
            self.watch_default()                 # blocks main thread; event-driven

    def main():
        ctrl = Controller()
        # SIGHUP from the UI (config or filter toggle changed) -> re-evaluate.
        signal.signal(signal.SIGHUP, lambda *_: ctrl.reload.set())
        ctrl.run()

    if __name__ == "__main__":
        try:
            main()
        except KeyboardInterrupt:
            pass
  '';

  auto-mic-daemon-sh = pkgs.writeShellScriptBin "audio-auto-mic-daemon" ''
    export PATH="${pkgs.pulseaudio}/bin:${pkgs.pipewire}/bin:$PATH"
    export AUTO_MIC_VAD_METER="${vad-meter-sh}/bin/audio-vad-meter"
    export AUTO_MIC_SET_INPUT="${rnnoise-set-input-sh}/bin/audio-rnnoise-set-input"
    export AUTO_MIC_GET_INPUT="${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input"
    exec ${pkgs.python3}/bin/python ${auto-mic-daemon-py}
  '';

  # ── Auto-switch UI: read + mutate the daemon's config ───────────────────────
  # The quickshell input picker uses these to show candidate state and to edit
  # it (toggle a mic into the set, reorder priority, flip the master switch).
  # Same config file the daemon watches, so edits apply live.
  auto-mic-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/auto-mic/config.json"'';

  # Emits the current auto-switch state as parseable lines:
  #   enabled|<0|1>
  #   cand|<priorityIndex>|<source node.name>   (one per candidate, in order)
  #   active|<source node.name>                  (the mic the daemon is live on)
  auto-mic-read-sh = pkgs.writeShellScriptBin "audio-auto-mic-read" ''
    cfg=${auto-mic-config-path}
    state="''${XDG_RUNTIME_DIR:-/tmp}/auto-mic-active"
    if [ -f "$cfg" ]; then
      ${pkgs.jq}/bin/jq -r '
        "enabled|" + (if .enabled then "1" else "0" end),
        ((.candidates // []) | to_entries[] | "cand|\(.key)|\(.value)")
      ' "$cfg" 2>/dev/null || echo "enabled|0"
    else
      echo "enabled|0"
    fi
    [ -f "$state" ] && echo "active|$(cat "$state")"
    exit 0
  '';

  # Mutate the config. Subcommands:
  #   toggle-enabled            flip the master auto-switch on/off
  #   set-enabled <1|0>         force the master auto-switch on/off
  #   suspend                   MIX on: disable auto-switch, remember it was on
  #   resume                    MIX off: re-enable iff suspend disabled it
  #   toggle <source.name>      add the mic to the candidate set, or remove it
  #   up|down <source.name>     move the mic earlier/later in priority
  auto-mic-mutate-sh = pkgs.writeShellScriptBin "audio-auto-mic-mutate" ''
    cfg=${auto-mic-config-path}
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$cfg")"
    [ -f "$cfg" ] || echo '{"enabled":false,"candidates":[]}' > "$cfg"
    cmd="$1"; name="$2"
    jq=${pkgs.jq}/bin/jq
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    case "$cmd" in
      toggle-enabled)
        "$jq" '.enabled = ((.enabled // false) | not)' "$cfg" > "$tmp" ;;
      set-enabled)
        # $name is "1" or "0" — force the master auto-switch on/off. Clears
        # any MIX suspension: an explicit user choice outranks the memo that
        # MIX turned auto off (otherwise a later MIX-off resume would undo it).
        "$jq" --argjson v "$([ "$name" = "1" ] && echo true || echo false)" \
          '.enabled = $v | .mix_suspended = false' "$cfg" > "$tmp" ;;
      suspend)
        # MIX turned on: stand auto-switch down, but REMEMBER it was on so
        # MIX-off restores it. One-way set-enabled 0 here is how auto-switch
        # got silently lost for days (MIX on Sep 30 2026, never restored).
        "$jq" 'if .enabled == true
               then .enabled = false | .mix_suspended = true
               else . end' "$cfg" > "$tmp" ;;
      resume)
        # MIX turned off: restore auto-switch ONLY if MIX was what disabled
        # it — a user who had auto off keeps it off.
        "$jq" 'if .mix_suspended == true
               then .enabled = true | .mix_suspended = false
               else . end' "$cfg" > "$tmp" ;;
      toggle)
        "$jq" --arg n "$name" '
          .candidates = (.candidates // []) |
          if (.candidates | index($n)) then .candidates -= [$n]
          else .candidates += [$n] end' "$cfg" > "$tmp" ;;
      up)
        "$jq" --arg n "$name" '
          .candidates = (.candidates // []) |
          (.candidates | index($n)) as $i |
          if ($i == null or $i == 0) then .
          else .candidates = (.candidates[0:$i-1] + [.candidates[$i]] + [.candidates[$i-1]] + .candidates[$i+1:]) end
        ' "$cfg" > "$tmp" ;;
      down)
        "$jq" --arg n "$name" '
          .candidates = (.candidates // []) |
          (.candidates | index($n)) as $i | (.candidates | length) as $len |
          if ($i == null or $i >= $len - 1) then .
          else .candidates = (.candidates[0:$i] + [.candidates[$i+1]] + [.candidates[$i]] + .candidates[$i+2:]) end
        ' "$cfg" > "$tmp" ;;
      *) ${pkgs.coreutils}/bin/rm -f "$tmp"; echo "unknown command: $cmd" >&2; exit 1 ;;
    esac
    if [ -s "$tmp" ]; then ${pkgs.coreutils}/bin/mv "$tmp" "$cfg"; else ${pkgs.coreutils}/bin/rm -f "$tmp"; fi
    # Nudge the daemon to re-read config + re-evaluate (event-driven, no polling).
    ${pkgs.procps}/bin/pkill -HUP -f auto-mic-daemon.py 2>/dev/null || true
    echo done
  '';

  # ── Mix-set: which devices participate in MIX (blend / output-duplicate) ────
  # Separate from the auto-switch set (which is ordered). Two UNORDERED sets:
  #   sources  → mics that combined_mics blends   (empty = ALL, back-compat)
  #   sinks    → outputs that combined_out feeds   (empty = ALL, back-compat)
  # The quickshell chain-link button toggles membership per device, per tab.
  mixset-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/audio-mix/config.json"'';

  # Emit membership as parseable lines:  src|<node.name>   snk|<node.name>
  mixset-read-sh = pkgs.writeShellScriptBin "audio-mixset-read" ''
    cfg=${mixset-config-path}
    if [ -f "$cfg" ]; then
      ${pkgs.jq}/bin/jq -r '
        ((.sources // [])[] | "src|" + .),
        ((.sinks   // [])[] | "snk|" + .)
      ' "$cfg" 2>/dev/null
    fi
    exit 0
  '';

  # Toggle a device in/out of a set:  audio-mixset-mutate <src|snk> toggle <name>
  # Applies live: a source change nudges the mix-sync daemon (re-evaluates which
  # mics get delayed.* wrappers → combined_mics); a sink change rebuilds
  # combined_out's slave list if the output-duplicate is currently active.
  mixset-mutate-sh = pkgs.writeShellScriptBin "audio-mixset-mutate" ''
    cfg=${mixset-config-path}
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$cfg")"
    [ -f "$cfg" ] || echo '{"sources":[],"sinks":[]}' > "$cfg"
    kind="$1"; cmd="$2"; name="$3"
    case "$kind" in
      src) key=sources ;;
      snk) key=sinks ;;
      *) echo "bad kind: $kind" >&2; exit 1 ;;
    esac
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    apply=1
    case "$cmd" in
      toggle)
        # Plain add/remove. The set is EXPLICIT (seeded on MIX-enable with the
        # default device — see micblend-set / outdup-toggle), so no empty=all.
        ${pkgs.jq}/bin/jq --arg k "$key" --arg n "$name" '
          ([$k]) as $p | (getpath($p) // []) as $a |
          setpath($p; (if ($a | index($n)) then ($a - [$n]) else ($a + [$n]) end))
        ' "$cfg" > "$tmp" ;;
      seed)
        # Set to exactly [name] ONLY if currently empty — used when MIX turns on
        # so it starts with just the default device. No live re-apply (the
        # caller sets up the combine right after).
        apply=0
        ${pkgs.jq}/bin/jq --arg k "$key" --arg n "$name" '
          ([$k]) as $p | (getpath($p) // []) as $a |
          setpath($p; (if ($a | length) == 0 then [$n] else $a end))
        ' "$cfg" > "$tmp" ;;
      *) ${pkgs.coreutils}/bin/rm -f "$tmp"; echo "unknown command: $cmd" >&2; exit 1 ;;
    esac
    if [ -s "$tmp" ]; then ${pkgs.coreutils}/bin/mv "$tmp" "$cfg"; else ${pkgs.coreutils}/bin/rm -f "$tmp"; fi
    if [ "$apply" = 1 ]; then
      if [ "$kind" = src ]; then
        ${pkgs.procps}/bin/pkill -USR1 -f mix-sync-daemon.py 2>/dev/null || true
      else
        case "$name" in
          mesh:*)
            # Remote tailnet output: the audio-devices daemon owns the route
            # lifecycle (start/keep-alive), the proxy map, AND the combined_out
            # rebuild once the proxy exists. Poke it to reconcile now; it reloads
            # the combine itself, so we don't double-reload here.
            ${pkgs.procps}/bin/pkill -USR1 -f audio_devices.py 2>/dev/null || true ;;
          *)
            ${outdup-reload-sh}/bin/audio-outdup-reload 2>/dev/null || true ;;
        esac
      fi
    fi
    echo done
  '';

  list-sink-inputs-sh = pkgs.writeShellScriptBin "audio-list-sink-inputs" ''
    titlesfile=$(mktemp)
    namesfile=$(mktemp)
    sinksfile=$(mktemp)
    btfile=$(mktemp)
    trap "rm -f $titlesfile $namesfile $sinksfile $btfile" EXIT

    # bluez card MAC -> form factor (phone/headset/speaker/...), so bluetooth
    # A2DP-source streams can carry a device-type icon class.
    pactl list cards 2>/dev/null | awk '
      /^\tName: bluez_card\./ { mac=substr($2, 12) }
      /device\.form_factor/   { split($0, a, "\""); if (mac != "") { print mac "\001" a[2]; mac="" } }
    ' > "$btfile" || true

    hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | [(.pid|tostring), .title] | join("\u0001")' \
      > "$titlesfile" 2>/dev/null || true

    # sink index -> node.name, to hide streams parked on per-user Discord
    # null-sinks (see the awk below).
    pactl list short sinks > "$sinksfile" 2>/dev/null || true

    # Walk up the process tree to find the root electron/chromium ancestor
    # and identify the real application from its cmdline
    resolve_electron() {
      local pid=$1 current=$pid last=$pid ppid exe
      while true; do
        ppid=$(awk '/^PPid:/{print $2}' /proc/$current/status 2>/dev/null)
        [ -z "$ppid" ] || [ "$ppid" = "1" ] || [ "$ppid" = "0" ] && break
        exe=$(readlink /proc/$ppid/exe 2>/dev/null)
        case "$exe" in
          *electron*|*chromium*) last=$ppid; current=$ppid ;;
          *) break ;;
        esac
      done
      local cmdline
      cmdline=$(tr '\0' ' ' < /proc/$last/cmdline 2>/dev/null)
      case "$cmdline" in
        *[Vv]esktop*)  echo "Vesktop" ;;
        *[Dd]iscord*)  echo "Discord" ;;
        *[Ss]lack*)    echo "Slack" ;;
        *[Oo]bsidian*) echo "Obsidian" ;;
        *)
          # Extract app name from nix store path: /nix/store/hash-appname-version/
          echo "$cmdline" \
            | sed -n 's|.*/nix/store/[^/]*/\([^/ ]*\).*|\1|p' \
            | head -1 \
            | sed 's/-[0-9].*//'
          ;;
      esac
    }

    # Pre-compute names for electron-based sink input PIDs
    pactl list sink-inputs \
      | awk '/application\.process\.id/{split($0,a,"\""); print a[2]}' \
      | sort -u \
      | while read -r pid; do
          [ -z "$pid" ] && continue
          exe=$(readlink /proc/$pid/exe 2>/dev/null)
          case "$exe" in
            *electron*|*chromium*)
              name=$(resolve_electron "$pid")
              [ -n "$name" ] && printf '%s\001%s\n' "$pid" "$name"
              ;;
          esac
        done > "$namesfile"

    pactl list sink-inputs | awk -v tf="$titlesfile" -v nf="$namesfile" -v sf="$sinksfile" -v bf="$btfile" '
      ${audio-naming-awk}
      BEGIN {
        while ((getline line < tf) > 0) {
          idx = index(line, "\001")
          if (idx > 0) titles[substr(line,1,idx-1)] = substr(line,idx+1)
        }
        close(tf)
        while ((getline line < nf) > 0) {
          idx = index(line, "\001")
          if (idx > 0) enames[substr(line,1,idx-1)] = substr(line,idx+1)
        }
        close(nf)
        while ((getline line < sf) > 0) {
          n = split(line, sp, "\t")
          if (n >= 2) sinknames[sp[1]] = sp[2]
        }
        close(sf)
        while ((getline line < bf) > 0) {
          idx = index(line, "\001")
          if (idx > 0) btform[substr(line,1,idx-1)] = substr(line,idx+1)
        }
        close(bf)
      }
      # Internal plumbing streams are not apps — the canonical internal_node()
      # mask hides them: output.combined_out* duplicator streams get their own
      # rows in the dup-sink mixer of the popup, applvl.<n>.out balance-pool
      # bridges would show as phantom "Unknown" gauges, and the sync/castsync
      # loopback playback halves are represented by their device rows. Streams
      # that are deliberately app-LIKE (soundboard, tailnet-route-recv,
      # discordpeer.<id>.out per-user bridges) are not in the mask and keep
      # their gauges. Vesktop feed streams PARKED on a discord_user_* null-sink
      # are hidden by their sink: the per-user bridge is that voice, and a
      # visible feed gauge would fight the split (PerUserAudioSinks).
      function emit(    mac, ff) {
        if (id == "" || internal_node(nodename)) return
        if (sinknames[sinkidx] ~ /^discord_user_/) return
        title = (pid in titles) ? titles[pid] : ""
        if (pid in enames) name = enames[pid]
        # Streams with no owning application (bluez A2DP sources etc.) carry
        # the device description instead — show that rather than "Unknown",
        # and a synthetic bt-device:<form-factor> binary so the gauge can
        # icon them by device type instead of the unknown glyph.
        if (name == "Unknown" && devdesc != "") name = devdesc
        if (binary == "" && nodename ~ /^bluez_input\./) {
          mac = nodename; sub(/^bluez_input\./, "", mac); sub(/\.[0-9]+$/, "", mac)
          ff = (mac in btform) ? btform[mac] : "unknown"
          binary = "bt-device:" ff
        }
        printf "%s|%s|%s|%s|%s|%s|%s\n", id, name, vol, muted, binary, corked, title
      }
      /^Sink Input #/ {
        emit()
        id = substr($3, 2); name = "Unknown"; vol = 100; muted = 0; binary = ""; pid = ""; nodename = ""; corked = 0; sinkidx = ""; devdesc = ""
      }
      /device\.description/          { split($0, a, "\""); if (length(a) > 1) devdesc = a[2] }
      /^\tSink:/    { sinkidx = $2 }
      /Corked:/    { corked = ($2 == "yes") ? 1 : 0 }
      /Mute:/      { muted = ($2 == "yes") ? 1 : 0 }
      /Volume:.*%/ { match($0, /[0-9]+%/); if (RSTART > 0) vol = substr($0, RSTART, RLENGTH-1) + 0 }
      /application\.name/            { split($0, a, "\""); if (length(a) > 1) name   = a[2] }
      /application\.process\.binary/ { split($0, a, "\""); if (length(a) > 1) binary = a[2] }
      /application\.process\.id/     { split($0, a, "\""); if (length(a) > 1) pid    = a[2] }
      /node\.name = /                { split($0, a, "\""); if (length(a) > 1) nodename = a[2] }
      END { emit() }
    '
  '';

  # Print the display name (from audio-naming-awk) of the current default
  # sink or source. Used by the bar; replaces the older getDefaultSink/
  # getDefaultSource scripts so naming stays consistent.
  #   Usage: default-display-name-sh <sink|source> [short]
  # Without "short": full display_name() like "Built In (Ryzen HD Audio)".
  # With "short":    short_name() — just the label or first 3 words of desc.
  default-display-name-sh = pkgs.writeShellScriptBin "audio-default-display-name" ''
    kind="$1"   # "sink" or "source"
    mode="''${2:-full}"
    default=$(pactl get-default-"$kind" 2>/dev/null)
    [ -z "$default" ] && exit 0
    # With noise cancellation on the default source is the virtual rnnoise_source
    # ("Noise Canceling Source"). Show the real hardware mic behind it instead.
    if [ "$kind" = "source" ] && [ "$default" = "rnnoise_source" ]; then
      fin=$(${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input)
      [ -n "$fin" ] && default="$fin"
    fi
    pactl list "''${kind}s" | awk -v target="$default" -v mode="$mode" '
      ${audio-naming-awk}
      function emit() {
        if (mode == "short") print short_name(port, alsa_card, alsa_device, desc)
        else                 print display_name(port, alsa_card, alsa_device, desc)
      }
      /^(Sink|Source) #/ {
        if (name == target) { emit(); name = ""; exit }
        name = ""; desc = ""; port = ""; alsa_card = ""; alsa_device = ""
      }
      /^\tName:/        { name = $2 }
      /^\tDescription:/ { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/ { port = $3 }
      /alsa\.card = /   { match($0, /"[^"]*"/); alsa_card   = substr($0, RSTART+1, RLENGTH-2) }
      /alsa\.device = / { match($0, /"[^"]*"/); alsa_device = substr($0, RSTART+1, RLENGTH-2) }
      END { if (name == target) emit() }
    '
  '';
  # ── Mix-sync daemon ─────────────────────────────────────────────────────────
  # Keeps every physical mic wrapped in a fixed-delay virtual source
  # `delayed.<node.name>` (a pw-loopback with --delay), and calibrates the
  # delays so all mics are time-aligned to the slowest one. combined_mics
  # captures the wrappers, NOT the raw mics — so MIX mode mixes in-phase.
  # A wireless dongle adds a large fixed transit delay its *reported* latency
  # says nothing about (see combine.latency-compensate comment in
  # pipewire.nix), so alignment is MEASURED: when the mix is live and a mic
  # pair has no stored offset, the daemon records both raw mics during normal
  # speech, cross-correlates, and stores the per-mic lag in
  # $XDG_STATE_HOME/audio-mix-sync/offsets.json. Known mics sync instantly
  # from the stored value (measured drift between sessions was < 0.1 ms).
  # Event-driven: pactl subscribe for source add/remove (wrapper lifecycle)
  # and for combined_mics state changes (calibration trigger). SIGHUP drops
  # stored offsets and forces a fresh calibration.
  mix-sync-daemon-py = pkgs.writeText "mix-sync-daemon.py" ''
    import json, math, os, select, signal, struct, subprocess, threading, time

    STATE_DIR = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "audio-mix-sync")
    OFFSETS = os.path.join(STATE_DIR, "offsets.json")

    CONFIG = os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "audio-mix", "config.json")

    def mix_set_sources():
        """The chosen mic subset for the blend. Empty = blend ALL mics
        (back-compat with the pre-selection behaviour)."""
        try:
            with open(CONFIG) as f:
                return set(json.load(f).get("sources") or [])
        except Exception:
            return set()

    AUTOMIX_CONFIG = os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "audio-automix", "config.json")

    def automix_plan():
        """(members, tie_sets) from an ENABLED automix config, else None.
        members = every automix mic (they define blend membership while
        automix owns the mix). tie_sets = mics sharing group+priority — the
        only mics that are ever OPEN simultaneously, hence the only ones
        whose delays must align. A solo-priority mic (the typical good desk
        mic) gets ZERO padding: automix gates fallbacks instead of mixing
        them, so padding the primary to the slowest mic — what the legacy
        global alignment does — would buy nothing and cost ~46 ms of live
        latency (Arctis radio transit)."""
        try:
            with open(AUTOMIX_CONFIG) as f:
                cfg = json.load(f)
            if not cfg.get("enabled"):
                return None
            members, ties = [], []
            for g in cfg.get("groups") or []:
                by_p = {}
                for m in g.get("mics") or []:
                    n = m.get("node")
                    if not n:
                        continue
                    members.append(n)
                    try:
                        p = int(m.get("priority", 1))
                    except Exception:
                        p = 1
                    by_p.setdefault(p, []).append(n)
                ties.extend([ms for ms in by_p.values() if len(ms) > 1])
            if not members:
                return None
            return (members, ties)
        except Exception:
            return None

    RATE = 48000
    REC_S = 12           # calibration recording length
    MAX_LAG_MS = 300     # search window; wireless links sit well inside this
    MIN_PEAK = 1500      # min 16-bit peak in BOTH mics to accept a measurement
    PROMINENCE = 1.5     # best/second-best xcorr ratio to accept a lag
    RETRY_S = 30         # min seconds between calibration attempts

    def log(*a):
        print("[mix-sync]", *a, flush=True)

    def real_mics():
        """Physical mics only: usb/pci ALSA + bluetooth. Excludes monitors,
        virtual sources (rnnoise/combined/delayed.*) and platform devices
        like snd_aloop (whose input half would pipe played audio into the
        mix)."""
        try:
            out = subprocess.run(["pactl", "list", "short", "sources"],
                                 capture_output=True, text=True, timeout=5).stdout
        except Exception:
            return []
        names = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                n = parts[1]
                if (n.startswith("alsa_input.usb-") or n.startswith("alsa_input.pci-")
                        or n.startswith("bluez_input.")):
                    names.append(n)
        return names

    def record_pair(a, b, seconds):
        """Simultaneously capture two raw mics; returns (samples_a, samples_b).
        Deadline-bounded and always reaps both parec captures — a stalled/suspended
        mic (no EOF) must NOT block forever: that used to hang calibrate() inside its
        try, so the finally never ran, self.measuring stayed True, and ALL future
        calibration wedged for the session."""
        def rec(mic):
            return subprocess.Popen(
                ["parec", "--rate=%d" % RATE, "--channels=1", "--format=s16le",
                 "-d", mic, "--client-name=mix-sync-cal"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        pa = pb = None
        try:
            pa, pb = rec(a), rec(b)
            want = RATE * seconds * 2
            deadline = time.monotonic() + seconds + 2.0   # hard cap over the nominal
            def read_until(p):
                buf = bytearray()
                fd = p.stdout.fileno()
                while len(buf) < want and time.monotonic() < deadline:
                    r, _, _ = select.select([fd], [], [], 0.2)
                    if not r:
                        continue
                    chunk = os.read(fd, want - len(buf))
                    if not chunk:      # EOF (device gone)
                        break
                    buf += chunk
                return bytes(buf)
            da = read_until(pa)
            db = read_until(pb)
        finally:
            for p in (pa, pb):
                if p is not None:
                    try:
                        p.kill(); p.wait(timeout=1)
                    except Exception:
                        pass
        n = min(len(da), len(db)) // 2
        return (struct.unpack("<%dh" % n, da[:n*2]),
                struct.unpack("<%dh" % n, db[:n*2]))

    def xcorr_lag(a, b):
        """Lag (samples) by which b trails a, or None if unconvincing.
        Coarse-to-fine search around the loudest 2s of a."""
        m = min(len(a), len(b))
        if m < RATE * 4:
            return None
        a, b = a[:m], b[:m]
        pa = max(max(a), -min(a)); pb = max(max(b), -min(b))
        if pa < MIN_PEAK or pb < MIN_PEAK:
            return None
        w = 480
        env = [max(abs(x) for x in a[i:i+w]) for i in range(0, m - w, w)]
        c = max(range(len(env)), key=lambda i: sum(env[max(0, i-10):i+10])) * w
        s0 = max(0, c - RATE); s1 = min(m, c + RATE)
        span = int(RATE * MAX_LAG_MS / 1000)

        def score(lag, step):
            acc = 0
            for i in range(s0, s1, step):
                j = i + lag
                if 0 <= j < m:
                    acc += a[i] * b[j]
            return acc

        coarse = [(score(l, 16), l) for l in range(-span, span + 1, 24)]
        coarse.sort(reverse=True)
        best = coarse[0][1]
        fine = [(score(l, 16), l)    # same stride as coarse so the
                for l in range(best - 144, best + 145, 2)]  # prominence ratio compares like with like
        fine.sort(reverse=True)
        peak_v, peak_l = fine[0]
        # prominence: compare against the best coarse score well away from
        # the winner — a diffuse correlation (no shared speech) fails this.
        rival = max((v for v, l in coarse if abs(l - peak_l) > RATE // 100),
                    default=0)
        if peak_v <= 0 or (rival > 0 and peak_v / rival < PROMINENCE):
            return None
        return peak_l

    class Daemon:
        def __init__(self):
            self.lock = threading.RLock()
            self.wrappers = {}     # mic -> (Popen, delay_s)
            self.lags = {}         # mic -> lag seconds (gauge: first ref = 0)
            self.measuring = False
            self.last_attempt = 0.0
            self.load()

        def load(self):
            try:
                with open(OFFSETS) as f:
                    self.lags = {k: float(v) for k, v in json.load(f).items()}
                log("loaded offsets:", self.lags)
            except Exception:
                self.lags = {}

        def save(self):
            try:
                os.makedirs(STATE_DIR, exist_ok=True)
                with open(OFFSETS, "w") as f:
                    json.dump(self.lags, f, indent=2)
            except Exception as e:
                log("state save failed:", e)

        def delays(self, mics):
            """Per-mic wrapper delay: pad everyone up to the slowest mic."""
            known = [self.lags.get(m, 0.0) for m in mics]
            top = max(known) if known else 0.0
            return {m: max(0.0, top - self.lags.get(m, 0.0)) for m in mics}

        def spawn(self, mic, delay):
            cmd = ["pw-loopback", "-n", "sync." + mic, "-c", "1",
                   "-m", "[ MONO ]", "--delay", "%.6f" % delay,
                   "-C", mic,
                   "-i", "node.passive=true node.dont-reconnect=true",
                   "-o", ("media.class=Audio/Source node.name=delayed.%s "
                          "node.description=\"%s (sync)\"") % (mic, mic)]
            p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL,
                                 start_new_session=True)
            self.wrappers[mic] = (p, delay)
            log("wrapper %s delay=%.1fms" % (mic, delay * 1000))

        def kill(self, mic):
            p, _ = self.wrappers.pop(mic)
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except Exception:
                try: p.terminate()
                except Exception: pass

        def sync_wrappers(self):
            with self.lock:
                present = real_mics()
                plan = automix_plan()
                if plan is not None:
                    # Automix owns the blend: membership from its groups,
                    # alignment only within tie-tiers (see automix_plan).
                    members, ties = plan
                    mics = [m for m in present if m in members]
                    # Fallback (verified silent-mic condition 2026-10-07): if
                    # EVERY member is absent (boot race, all unplugged) an
                    # empty wrap list leaves combined_mics with no capture
                    # streams at all — the whole chain goes silent even with
                    # healthy non-member mics plugged in. Any present mic
                    # beats guaranteed silence, so wrap them all until a
                    # member returns (then membership snaps back).
                    if not mics and present:
                        log("automix members all absent; blending present mics:", present)
                        mics = present
                    want = {m: 0.0 for m in mics}
                    for tie in ties:
                        sub = [m for m in tie if m in want]
                        if len(sub) > 1:
                            top = max(self.lags.get(m, 0.0) for m in sub)
                            for m in sub:
                                want[m] = max(0.0, top - self.lags.get(m, 0.0))
                else:
                    chosen = mix_set_sources()
                    mics = present
                    if chosen:                     # non-empty = blend only these
                        mics = [m for m in present if m in chosen]
                        # Same fallback for the legacy mix-set: it persists
                        # across sessions, so a set seeded on a since-removed
                        # mic would otherwise leave the blend empty forever.
                        if not mics and present:
                            log("mix-set mics all absent; blending present mics:", present)
                            mics = present
                    want = self.delays(mics)
                for mic in list(self.wrappers):
                    p, d = self.wrappers[mic]
                    dead = p.poll() is not None
                    stale = mic in want and abs(want[mic] - d) > 0.001
                    if mic not in want or dead or stale:
                        self.kill(mic)
                for mic, d in want.items():
                    if mic not in self.wrappers:
                        self.spawn(mic, d)

        def need_calibration(self):
            mics = real_mics()
            unknown = [m for m in mics if m not in self.lags]
            known = len(mics) - len(unknown)
            # with no known mic, one unknown anchors the gauge at 0 and is
            # not itself a measurement target — so 2+ unknowns are needed
            return len(mics) >= 2 and len(unknown) >= (2 if known == 0 else 1)

        def calibrate(self):
            with self.lock:
                if self.measuring:
                    return
                now = time.monotonic()
                if now - self.last_attempt < RETRY_S:
                    return
                self.last_attempt = now
                self.measuring = True
            try:
                mics = real_mics()
                if len(mics) < 2:
                    return
                ref = next((m for m in mics if m in self.lags), mics[0])
                if ref not in self.lags:
                    self.lags[ref] = 0.0
                targets = [m for m in mics if m != ref and m not in self.lags]
                for mic in targets:
                    log("calibrating %s vs %s (speak normally)" % (mic, ref))
                    a, b = record_pair(ref, mic, REC_S)
                    lag = xcorr_lag(a, b)
                    if lag is None:
                        log("no usable speech; will retry")
                        continue
                    self.lags[mic] = self.lags[ref] + lag / RATE
                    log("measured: %s trails %s by %.2f ms"
                        % (mic, ref, lag / 48.0))
                    self.save()
                self.sync_wrappers()
            finally:
                with self.lock:
                    self.measuring = False

        def maybe_calibrate_async(self):
            if self.need_calibration():
                threading.Thread(target=self.calibrate, daemon=True).start()

        def on_setchange(self):
            # SIGUSR1: the mix-set changed. Just re-sync which mics have
            # wrappers (combined_mics follows delayed.*) — do NOT drop the
            # hard-won calibration offsets the way reset() does.
            self.sync_wrappers()
            self.maybe_calibrate_async()

        def reset(self):
            with self.lock:
                log("SIGHUP: dropping stored offsets, recalibrating")
                self.lags = {}
                self.save()
                self.last_attempt = 0.0
                self.sync_wrappers()
            self.maybe_calibrate_async()

        def run(self):
            self.sync_wrappers()
            self.maybe_calibrate_async()
            try:
                proc = subprocess.Popen(["pactl", "subscribe"],
                                        stdout=subprocess.PIPE, text=True)
            except Exception as e:
                log("subscribe failed:", e)
                return
            for line in proc.stdout:
                if " on source #" in line:
                    if "'new'" in line or "'remove'" in line:
                        self.sync_wrappers()
                        self.maybe_calibrate_async()
                    elif "'change'" in line:
                        # combined_mics going RUNNING (mix turned on) arrives
                        # as change events; cheap gate inside decides.
                        self.maybe_calibrate_async()

        def stop(self):
            for mic in list(self.wrappers):
                self.kill(mic)

    def main():
        d = Daemon()
        signal.signal(signal.SIGHUP, lambda *_: d.reset())
        signal.signal(signal.SIGUSR1, lambda *_: d.on_setchange())
        try:
            d.run()
        finally:
            d.stop()

    if __name__ == "__main__":
        try:
            main()
        except KeyboardInterrupt:
            pass
  '';

  mix-sync-daemon-sh = pkgs.writeShellScriptBin "audio-mix-sync-daemon" ''
    export PATH="${pkgs.pulseaudio}/bin:${pkgs.pipewire}/bin:$PATH"
    exec ${pkgs.python3}/bin/python ${mix-sync-daemon-py}
  '';

  # ── Automix: gain-based successor to the auto-mic switcher ─────────────────
  # The switcher's fragility all lived in per-decision GRAPH mutation (re-link
  # the filter input, sweep strays, fight WirePlumber); every live failure —
  # doubled voice, dead feed after a switch, stuck selections — was that layer.
  # Automix keeps the graph STATIC: every member mic feeds combined_mics
  # permanently, combined_mics feeds the AEC→RNNoise chain, and decisions are
  # volume ramps on the combiner's per-mic capture streams. A wrong decision is
  # briefly suboptimal audio, never a dead mic.
  #
  # Config: $XDG_CONFIG_HOME/audio-automix/config.json
  #   { "enabled": false,
  #     "groups": [ { "name": "Group 1", "enabled": true,
  #                   "mics": [ {"node": "alsa_input...", "priority": 1},
  #                             {"node": "alsa_input...", "priority": 2} ] } ] }
  # A group with "enabled": false stays configured but fully gated (the UI
  # group-tab checkbox).
  # Groups are independent people/channels: they always MIX with each other.
  # Within a group, priorities form tiers (lower number = preferred): the
  # highest-priority tier with speech evidence is OPEN (all its mics at their
  # trim volume), every other tier is GATED (near-silent). Equal priorities =
  # one tier = plain blend. Decisions reuse the auto-mic evidence stack: VAD
  # meters per mic, min-stat noise floors, the playback echo guard, dead-mic
  # fast failover. See auto-mic-daemon-py above for the rationale behind each
  # knob; the semantics here are per-GROUP instead of global.
  #
  # Latency: mix-sync aligns delays only within a tie-tier (see its
  # automix-aware delay policy) — a solo-priority mic (the usual "good desk
  # mic") is never padded to match a slower fallback mic.
  automix-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/audio-automix/config.json"'';

  automix-daemon-py = pkgs.writeText "automix-daemon.py" ''
    import json, os, re, signal, subprocess, threading, time

    CONFIG = os.environ.get("AUTOMIX_CONFIG") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "audio-automix", "config.json")
    TRIMS = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "audio-automix", "trims.json")
    BLEED = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "audio-automix", "bleed.json")
    ENVS = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "audio-automix", "envelopes.json")
    GATE = os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
        "audio-automix", "gate.json")
    STATE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "automix-open")
    VAD_METER = os.environ.get("AUTOMIX_VAD_METER") or "qs-vad-meter"
    SET_INPUT = os.environ.get("AUTOMIX_SET_INPUT") or "qs-rnnoise-set-input"
    GET_INPUT = os.environ.get("AUTOMIX_GET_INPUT") or "qs-rnnoise-current-input"
    LIST_BLEND = os.environ.get("AUTOMIX_LIST_BLEND") or "audio-list-blend-mics"
    AUTOMIC_MUTATE = os.environ.get("AUTOMIX_AUTOMIC_MUTATE") or "audio-auto-mic-mutate"
    RN_SOURCE = "rnnoise_source"
    COMBINED = "combined_mics"
    GATE_PCT = 2         # cubic pactl %, ~ -100 dB: inaudible but stream stays live

    DEFAULTS = {
        "enabled": False,
        "groups": [],
        # Evidence thresholds — same meanings as the auto-mic daemon's.
        "snr_min": 6.0,
        "near_snr": 14.0,
        "stick_db": 3.0,
        "viable_ms": 180,
        "grace_ms": 150,
        "hysteresis_ms": 200,   # move UP to a preferred tier
        "drop_ms": 1200,        # fall DOWN to a fallback tier (walk-away)
        "settle_ms": 400,
        "flap_window_ms": 8000,
        "flap_hold_ms": 3000,
        "dead_level": 4.0,
        "dead_hold_ms": 150,
        "dead_cut_ms": 150,
        "vad_agg": 3,
        "echo_guard": True,
        "echo_clear_ms": 400,
        "echo_guard_agg": 2,
        # ── per-mic speech ENVELOPES (the no-magic-numbers endgame) ──────
        # Each mic LEARNS what "hearing you well" means for IT: a max-biased
        # envelope of the SNR it sees while it is the open mic and you are
        # speaking. All position bars derive from the mic's own envelope as
        # RELATIVE drops, so a hot headset and a modest desk mic stop being
        # judged on one universal scale — the single global near_snr made
        # lean-back and walk-away UNFIXABLE together (tune for one, break
        # the other; lived twice, 2026-10-06). Until a mic has an envelope
        # (~20 s of open speech), the global constants apply unchanged.
        "env_near_frac": 0.6,       # "near"/"comfortable" = this FRACTION of
                                    # the mic's learned envelope (clamped
                                    # 8..20). A fraction scales with however
                                    # loud the envelope really is; the fixed
                                    # -dB drops it replaced only worked at
                                    # one magnitude (env 19 -> unleavable
                                    # bar 7; env 34 -> churn bar 22, both
                                    # lived 2026-10-06). Near and immune are
                                    # ONE judgment: no band between them for
                                    # dominance to exploit (the lean-back
                                    # steal); dominance acts only in the
                                    # stick-discount cling zone below near
                                    # (the walk-away stall it exists for).
        "env_min_db": 15.0,         # envelope floor (sanity clamp)
        "bleed_margin_db": 8.0,  # playback-credibility margin: while the
                               # speakers carry voice, a mic's speech evidence
                               # counts only if its SNR beats the mic's OWN
                               # measured playback bleed by this much. Replaces
                               # the blunt freeze — switching works THROUGH
                               # continuous playback once profiles are learned,
                               # and an out-of-earshot mic (bleed ~0) is always
                               # credible. Margins are relative, so this
                               # transfers across rooms/volumes/mics.
        "dominate_db": 8.0,    # a tier hearing you THIS much more clearly than
                               # the open tier takes over even while the open
                               # tier still scrapes its bar: walking away left
                               # the desk mic at SNR ~12 (distant but "near")
                               # while the headset read ~23 — without this the
                               # handoff waits for the desk mic to fully lose
                               # you (~6 extra seconds, traced 2026-10-06)
        "dominate_ms": 300,    # hold time for a dominance switch — short on
                               # purpose: the dB differential is the evidence,
                               # and every extra ms is spent on a mic that is
                               # gating/garbling distant speech
        "shadow_ms": 300,      # SEAMLESSNESS: opening an extra mic is nearly
                               # free in a gain mixer, staying deaf is not —
                               # when the open tier is weak WHILE another tier
                               # hears speech, and that mismatch SUSTAINS this
                               # long, the other tier shadow-opens (full trim)
                               # without waiting for switch-grade confidence;
                               # the real handoff decision proceeds underneath.
                               # Long enough that at-desk sentence starts
                               # (mismatch for ~100 ms) never double the
                               # voice; short enough that mid-walk speech is
                               # carried before the open mic degrades far.
        "shadow_linger_ms": 800,  # shadow closes this long after the open
                               # tier is confidently strong again (false
                               # alarm: user stayed at the mic)
        "shadow_max_ms": 2500, # hard deadline on the overlap: past this the
                               # shadow either promotes to open (open tier
                               # still weak — it has proven itself) or is
                               # about to be lingered closed. Dual-open is a
                               # bridge, never a steady state (doubled voice
                               # in the acoustic in-between, 2026-10-06)
        "shadow_gain_db": -10.0,  # the shadow rides UNDER the open mic, not
                               # beside it: the two mics sit ~30 ms apart
                               # (wireless transit; true alignment would cost
                               # the primary mic that latency permanently —
                               # rejected), so an equal-level overlap reads
                               # as a double voice. A -10 dB shade still
                               # carries every walk-away word and promotes
                               # to full trim the moment it wins.
        "gate_autofit": True,  # auto-calibrate the chain's post-RNNoise level
                               # gate: track the USER'S measured speech level at
                               # the chain output and keep the gate threshold a
                               # RELATIVE margin below it. Absolute dBFS
                               # thresholds don't transfer across mics/gains/
                               # rooms (explicit user requirement 2026-10-06);
                               # a speech-relative margin does. The values in
                               # pipewire.nix are cold-boot seeds only.
        "gate_margin_db": 25.0,  # threshold sits this far below tracked speech
        "gate_noise_headroom_db": 6.0,  # ...but always this far ABOVE the
                               # tracked residue ceiling: speech-25 alone put
                               # the gate under the loudest fan-residue
                               # moments, and the leaks flashed Discord's
                               # speaking indicator (2026-10-06). Every leak
                               # is a non-voiced output window that teaches
                               # the calibrator where that ceiling is.
        "gate_min_db": -60.0,  # clamp: never so low the gate stops gating...
        "gate_max_db": -35.0,  # ...nor so high it can eat quiet speech
        "gate_speech_ms": 300,  # the autofit only LEARNS the speech level from
                               # a voiced run sustained at least this long. A
                               # keyboard click or fan burst trips RNNoise's
                               # VAD for a frame or two at high SNR; without a
                               # duration floor the calibrator banked those as
                               # "speech", dragging the tracked level (and the
                               # gate with it) into the floor whenever the user
                               # was quiet but the room was not (2026-10-09).
                               # Real speech sustains well past 300 ms; impulse
                               # noise cannot. Longer than the 180 ms mic-
                               # SELECTION viability bar on purpose: mis-banking
                               # the calibration is costlier than a momentary
                               # wrong mic pick.
        "crossfade_ms": 120,    # gain ramp length (make-before-break)
        "ramp_steps": 4,
    }

    def log(*a):
        print("[automix]", *a, flush=True)

    def load_config():
        cfg = dict(DEFAULTS)
        try:
            with open(CONFIG) as f:
                user = json.load(f)
            if isinstance(user, dict):
                cfg.update(user)
        except FileNotFoundError:
            pass
        except Exception as e:
            log("config parse error, using defaults:", e)
        return cfg

    def ensure_config():
        if os.path.exists(CONFIG):
            return
        try:
            os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
            with open(CONFIG, "w") as f:
                json.dump({"enabled": False,
                           "groups": [{"name": "Group 1", "mics": []}]}, f, indent=2)
            log("wrote default disabled config at", CONFIG)
        except Exception as e:
            log("could not write default config:", e)

    def run_out(cmd, timeout=5):
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=timeout).stdout
        except Exception:
            return ""

    def default_source():
        return run_out(["pactl", "get-default-source"]).strip()

    def default_sink():
        return run_out(["pactl", "get-default-sink"]).strip()

    def sink_is_headphones(name):
        """Same classification rule as the AEC auto daemon: only sinks we
        positively KNOW are worn audio (headphone/headset wording or bluez)
        count; everything else is treated as room speakers."""
        if not name:
            return False
        out = run_out(["pactl", "list", "sinks"])
        blk, hay = False, [name]
        for line in out.splitlines():
            if line.startswith("\tName:"):
                blk = line.split(":", 1)[1].strip() == name
            elif blk and ("Description:" in line or "Active Port:" in line
                          or "device.form_factor" in line):
                hay.append(line)
        return bool(re.search(r"headphone|headset|bluez", " ".join(hay), re.I))

    def present_sources():
        out = run_out(["pactl", "list", "short", "sources"])
        names = set()
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                names.add(parts[1])
        return names

    # The combiner's per-mic capture streams: {real mic -> (stream id, vol %)}.
    # LIST_BLEND already unwraps the delayed.<mic> wrappers to the real mic.
    def blend_streams():
        res = {}
        for line in run_out([LIST_BLEND]).splitlines():
            parts = line.split("|")
            if len(parts) >= 4:
                try:
                    res[parts[1]] = (parts[0], int(parts[3]))
                except ValueError:
                    pass
        return res

    def set_stream_vol(sid, pct):
        try:
            subprocess.run(["pactl", "set-source-output-volume", sid,
                            "%d%%" % int(pct)], timeout=5,
                           stderr=subprocess.DEVNULL)
        except Exception:
            pass

    # One VAD meter per mic — identical machinery to the auto-mic daemon's
    # (see its Meter class comments for the field semantics).
    class Meter:
        def __init__(self, mic, cfg, on_line):
            self.mic = mic
            self.grace_s = cfg["grace_ms"] / 1000.0
            self.dead_level = cfg["dead_level"]
            self.on_line = on_line
            self.lock = threading.Lock()
            self.snr = 0.0
            self.level = 100.0
            self.last_line = 0.0
            self.dead_since = None
            self.last_voiced = 0.0
            self.voice_start = 0.0
            self.snr_ewma = 0.0
            self.proc = subprocess.Popen([VAD_METER, mic, str(cfg["vad_agg"])],
                                         stdout=subprocess.PIPE,
                                         text=True, start_new_session=True)
            self.thread = threading.Thread(target=self._read, daemon=True)
            self.thread.start()

        def _read(self):
            for line in self.proc.stdout:
                parts = line.split()
                if len(parts) != 3:
                    continue
                try:
                    sp, snr, level = int(parts[0]), float(parts[1]), float(parts[2])
                except ValueError:
                    continue
                now = time.monotonic()
                with self.lock:
                    self.level = level
                    self.last_line = now
                    if level < self.dead_level:
                        if self.dead_since is None:
                            self.dead_since = now
                    else:
                        self.dead_since = None
                    if sp:
                        if (now - self.last_voiced) > self.grace_s:
                            self.voice_start = now
                            self.snr_ewma = snr
                        else:
                            self.snr_ewma = 0.5 * snr + 0.5 * self.snr_ewma
                        self.last_voiced = now
                        self.snr = snr
                if sp:
                    try:
                        self.on_line()
                    except Exception:
                        pass

        def viable(self, now, snr_min, viable_ms):
            with self.lock:
                if (now - self.last_voiced) > self.grace_s:
                    return False
                if self.snr_ewma < snr_min:
                    return False
                return (now - self.voice_start) * 1000.0 >= viable_ms

        def alive(self):
            return self.proc.poll() is None

        def is_dead(self, now, hold_ms):
            with self.lock:
                if (now - self.last_line) > 0.5:
                    return False
                return (self.dead_since is not None
                        and (now - self.dead_since) * 1000.0 >= hold_ms)

        def stop(self):
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except Exception:
                try:
                    self.proc.terminate()
                except Exception:
                    pass

    # Per-group tier state machine. Decisions mirror the auto-mic daemon's
    # _select, generalised mic -> tier: a tier's evidence is its best member's.
    class Group:
        def __init__(self, idx, name):
            self.idx = idx
            self.name = name
            self.enabled = True    # unticked group = present but fully gated
            self.tiers = []        # [(priority, [mics])] ascending priority number
            self.open_tier = None  # priority number currently open (None = none yet)
            self.shadow_tier = None   # extra tier held open mid-transition
            self.shadow_since = 0.0   # monotonic the shadow opened
            self.shadow_strong = 0.0  # monotonic the open tier last looked strong
            self.mismatch_since = 0.0 # monotonic the shadow CONDITION began
            self.pending = None
            self.pending_since = 0.0
            self.last_switch = 0.0
            self.left_at = {}      # tier -> monotonic when last closed

        def set_mics(self, mics):
            by_prio = {}
            for m in mics:
                try:
                    p = int(m.get("priority", 1))
                except Exception:
                    p = 1
                by_prio.setdefault(p, []).append(m.get("node"))
            self.tiers = sorted(by_prio.items())
            prios = [p for p, _ in self.tiers]
            if self.open_tier not in prios:
                self.open_tier = prios[0] if prios else None
            if self.shadow_tier not in prios:
                self.shadow_tier = None

        def all_mics(self):
            return [m for _, ms in self.tiers for m in ms]

        def _tier_mics(self, prio):
            for p, ms in self.tiers:
                if p == prio:
                    return list(ms)
            return []

        def open_mics(self):
            if not self.enabled:
                return []          # group unticked: everything in it stays gated
            return self._tier_mics(self.open_tier) if self.open_tier is not None else []

        def shadow_mics(self):
            # Shadow tier rides along during transitions so the user is
            # never inaudible while the handoff decision settles — at
            # REDUCED gain (see shadow_gain_db): the two mics are ~30 ms
            # apart (wireless transit) and an equal-level overlap reads as
            # an audible double voice; a -10 dB shade underneath does not.
            if (not self.enabled or self.shadow_tier is None
                    or self.shadow_tier == self.open_tier):
                return []
            return self._tier_mics(self.shadow_tier)

    class Controller:
        def __init__(self):
            self.cfg = load_config()
            self.meters = {}         # mic -> Meter
            self.ref_meter = None
            self.ref_sink = None
            self.out_meter = None    # rnnoise_source tap (gate auto-calibration)
            self.speech_db = None    # tracked speech level at the chain output
            self.noise_db = None     # tracked residue/leak ceiling at the output
            self.gate_db = None      # last gate threshold we applied
            self.gate_dirty = 0.0    # last unsaved speech/noise change (0 = clean)
            self.bleed = {}          # mic -> learned playback-bleed SNR
            self.bleed_n = {}        # mic -> sample count (gates credibility)
            self.bleed_dirty = 0.0   # last unsaved-change time (0 = clean)
            self.env = {}            # mic -> close-speech SNR envelope
            self.env_n = {}          # mic -> sample count (gates use)
            self.env_dirty = 0.0
            self.gate_node = None    # cached rnnoise_source node id
            self.gate_at = 0.0
            self.groups = []
            self.trims = {}          # mic -> open volume pct
            self.was_enabled = False
            self.verify_timer = None
            self.lock = threading.RLock()
            self.reload = threading.Event()
            self.load_trims()

        # ── trims (per-mic open volume, persisted) ───────────────────────
        def load_trims(self):
            try:
                with open(TRIMS) as f:
                    self.trims = {k: int(v) for k, v in json.load(f).items()}
            except Exception:
                self.trims = {}
            try:
                with open(BLEED) as f:
                    raw = json.load(f)
                self.bleed = {k: float(v[0]) for k, v in raw.items()}
                self.bleed_n = {k: int(v[1]) for k, v in raw.items()}
            except Exception:
                self.bleed, self.bleed_n = {}, {}
            try:
                with open(ENVS) as f:
                    raw = json.load(f)
                self.env = {k: float(v[0]) for k, v in raw.items()}
                self.env_n = {k: int(v[1]) for k, v in raw.items()}
            except Exception:
                self.env, self.env_n = {}, {}
            # Gate calibration (speech/noise level): without this the daemon
            # boots with speech_db None and must RE-LEARN from scratch after
            # every reboot/rebuild — a warm-up window where the user is
            # inaudible until they have spoken enough to converge. The levels
            # are a property of the mic + room + gain, stable across restarts;
            # a stale value is a fine starting estimate the EWMA refines.
            # Sanity-bounded so a corrupt file can't seed an absurd gate.
            try:
                with open(GATE) as f:
                    g = json.load(f)
                s = g.get("speech_db"); n = g.get("noise_db")
                if isinstance(s, (int, float)) and -80.0 <= s <= 0.0:
                    self.speech_db = float(s)
                if isinstance(n, (int, float)) and -90.0 <= n <= 0.0:
                    self.noise_db = float(n)
            except Exception:
                pass

        def save_gate(self):
            try:
                os.makedirs(os.path.dirname(GATE), exist_ok=True)
                tmp = GATE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({"speech_db": self.speech_db,
                               "noise_db": self.noise_db}, f, indent=2)
                os.replace(tmp, GATE)
                self.gate_dirty = 0.0
            except Exception as e:
                log("gate save failed:", e)

        def save_envs(self):
            try:
                os.makedirs(os.path.dirname(ENVS), exist_ok=True)
                tmp = ENVS + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({k: [self.env[k], self.env_n.get(k, 0)]
                               for k in self.env}, f, indent=2)
                os.replace(tmp, ENVS)
                self.env_dirty = 0.0
                log("speech envelopes:", {k[11:31]: round(v, 1)
                                          for k, v in self.env.items()})
            except Exception as e:
                log("env save failed:", e)

        # Per-mic "near" bar: within env_near_drop of THIS mic's learned
        # close-speech envelope; global near_snr until the envelope exists.
        def near_bar(self, mic):
            # FRACTION of the envelope, not an offset: a fixed -12 dB drop
            # only made sense at one envelope magnitude — with an honest
            # percentile envelope of 19 it put the bar at 7 (pod unleavable,
            # walk-away glacial), while at 34 it had put it at 22 (desk
            # churn). env*0.6 lands proportionally: 19 -> ~12, 26 -> ~16,
            # 34 -> 20. Clamped to broad sanity rails either way.
            if self.env_n.get(mic, 0) >= 300 and mic in self.env:
                return max(8.0, min(20.0,
                           self.env[mic] * self.cfg.get("env_near_frac", 0.6)))
            return self.cfg.get("near_snr", 14.0)

        # Comfortable == near, by design (see env_immune_db comment): one
        # judgment, no band between them for dominance to exploit.
        def immune_bar(self, mic):
            if self.env_n.get(mic, 0) >= 300 and mic in self.env:
                return self.near_bar(mic)
            return self.cfg.get("near_snr", 14.0) + self.cfg.get("dominate_immune_db", 4.0)

        # Envelope learning: ONLY while the mic is open and carrying real
        # user speech (that state is what "your close speech on this mic"
        # means). Max-biased: fast toward louder evidence, glacial decay so
        # one quiet mumbly hour doesn't erode the reference; floored.
        def _env_learn(self, now):
            for g in self.groups:
                for mic in g.open_mics():
                    mt = self.meters.get(mic)
                    if mt is None:
                        continue
                    with mt.lock:
                        voiced = (now - mt.last_voiced) <= mt.grace_s
                        snr = mt.snr_ewma
                    if not voiced or snr <= 0:
                        continue
                    cur = self.env.get(mic)
                    if cur is None:
                        self.env[mic] = max(snr, self.cfg.get("env_min_db", 15.0))
                    elif snr > cur:
                        # ~83rd-percentile tracker (5:1 asymmetric EWMA), NOT
                        # a peak-chaser: the max-biased first version learned
                        # the user's LOUDEST projection (env 34-35), every
                        # derived bar landed above their normal relaxed
                        # speech, and the daemon churned shadow/promote
                        # cycles while they sat still at the mic
                        # (2026-10-06 17:01, doubling at the desk).
                        self.env[mic] = 0.95 * cur + 0.05 * snr
                    else:
                        self.env[mic] = max(self.cfg.get("env_min_db", 15.0),
                                            0.99 * cur + 0.01 * snr)
                    self.env_n[mic] = self.env_n.get(mic, 0) + 1
            if self.env_dirty == 0.0:
                self.env_dirty = now
            elif (now - self.env_dirty) > 60.0:
                self.save_envs()

        def save_bleed(self):
            try:
                os.makedirs(os.path.dirname(BLEED), exist_ok=True)
                tmp = BLEED + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({k: [self.bleed[k], self.bleed_n.get(k, 0)]
                               for k in self.bleed}, f, indent=2)
                os.replace(tmp, BLEED)
                self.bleed_dirty = 0.0
                log("bleed profiles:", {k[11:31]: round(v, 1)
                                        for k, v in self.bleed.items()})
            except Exception as e:
                log("bleed save failed:", e)

        # ── playback-bleed learning (driven by the REFERENCE meter) ──────
        # While the speakers carry voice, sample how loudly each candidate
        # mic hears it. Low-quantile tracking (fast down, slow up): the
        # user's own intermittent speech during playback spikes upward and
        # is resisted; sustained pure playback pulls the estimate to the
        # true bleed. A mic the playback can't reach samples 0 — it becomes
        # ALWAYS credible (the other-room headset). Estimator-pollution
        # lesson applied from the start (see the gate noise tracker).
        def _bleed_sample(self):
            with self.lock:
                if not self.enabled():
                    return
                now = time.monotonic()
                for mic, mt in self.meters.items():
                    with mt.lock:
                        snr = mt.snr_ewma if (now - mt.last_voiced) <= mt.grace_s else 0.0
                        lvl = mt.level
                    # A DEAD mic (powered-off headset) hears nothing and
                    # would learn bleed ~0 — which flips to "fully credible
                    # next to the speakers" the moment it powers back on,
                    # resurrecting the yank bug with authority. The deaf
                    # don't teach (verified live: off Arctis sampled 471
                    # windows of 0.0, 2026-10-06).
                    if lvl < self.cfg.get("dead_level", 4.0):
                        continue
                    cur = self.bleed.get(mic)
                    if cur is None:
                        self.bleed[mic] = snr
                    elif snr < cur:
                        self.bleed[mic] = 0.90 * cur + 0.10 * snr
                    else:
                        self.bleed[mic] = 0.99 * cur + 0.01 * snr
                    self.bleed_n[mic] = self.bleed_n.get(mic, 0) + 1
                if self.bleed_dirty == 0.0:
                    self.bleed_dirty = now
                elif (now - self.bleed_dirty) > 30.0:
                    self.save_bleed()

        def save_trims(self):
            try:
                os.makedirs(os.path.dirname(TRIMS), exist_ok=True)
                tmp = TRIMS + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(self.trims, f, indent=2)
                os.replace(tmp, TRIMS)
            except Exception as e:
                log("trim save failed:", e)

        def enabled(self):
            return bool(self.cfg.get("enabled")) and any(
                g.all_mics() for g in self.groups)

        def member_mics(self):
            return [m for g in self.groups for m in g.all_mics()]

        # ── graph pinning (ONCE per enable, not per decision) ────────────
        def pin_graph(self):
            cur = run_out([GET_INPUT]).strip()
            if cur != COMBINED:
                subprocess.run([SET_INPUT, COMBINED], timeout=5)
            if default_source() != RN_SOURCE:
                subprocess.run(["pactl", "set-default-source", RN_SOURCE],
                               timeout=5)

        # ── meters ───────────────────────────────────────────────────────
        def _sync_meters(self):
            present = present_sources()
            want = (set(self.member_mics()) & present) if self.enabled() else set()
            for mic in list(self.meters):
                if mic not in want or not self.meters[mic].alive():
                    self.meters.pop(mic).stop()
            for mic in want:
                if mic not in self.meters:
                    self.meters[mic] = Meter(mic, self.cfg, self.on_meter_update)
            sink = default_sink() if (want and self.cfg.get("echo_guard", True)) else ""
            # Headphone-class output: no acoustic path from playback to the
            # room mics (and the Arctis earcups measurably don't even reach
            # their own boom mic), so a guard here only does harm — audio
            # playing in the user's EARS froze all switching, and walking
            # away while listening never handed off (2026-10-06). Guard only
            # when the room can hear the playback, same classification as
            # the AEC auto daemon.
            if sink and sink_is_headphones(sink):
                sink = ""
            if self.ref_meter is not None and (
                    not sink or self.ref_sink != sink or not self.ref_meter.alive()):
                self.ref_meter.stop()
                self.ref_meter = None
                self.ref_sink = None
            if sink and self.ref_meter is None:
                rcfg = dict(self.cfg)
                rcfg["vad_agg"] = int(self.cfg.get("echo_guard_agg", 2))
                self.ref_meter = Meter(sink + ".monitor", rcfg, self._bleed_sample)
                self.ref_sink = sink
            # Gate auto-calibration tap on the chain OUTPUT: its voiced
            # windows are by definition the user's speech as every consumer
            # hears it, on whatever mic/gain this system has.
            want_out = bool(want) and bool(self.cfg.get("gate_autofit", True))
            if self.out_meter is not None and (
                    not want_out or not self.out_meter.alive()):
                self.out_meter.stop()
                self.out_meter = None
            if want_out and self.out_meter is None:
                self.out_meter = Meter(RN_SOURCE, dict(self.cfg), lambda: None)

        # ── gains ────────────────────────────────────────────────────────
        # Converge every member stream to its target (trim when open, GATE
        # when not) with a ramped crossfade: raise opening mics step-by-step
        # BEFORE lowering closing ones, so the voice never has a gap.
        def apply_gains(self, ramp=True):
            streams = blend_streams()
            opens, closes = [], []
            open_set, shadow_set = set(), set()
            for g in self.groups:
                open_set.update(g.open_mics())
                shadow_set.update(g.shadow_mics())
            # cubic pactl %: an X dB shade is pct * 10^(X/60)
            shade = 10.0 ** (float(self.cfg.get("shadow_gain_db", -10.0)) / 60.0)
            for mic in self.member_mics():
                if mic not in streams:
                    continue        # wrapper not up yet; node event re-applies
                sid, vol = streams[mic]
                if mic in shadow_set:
                    # Reduced-gain overlap carrier. Never learn trims from
                    # this state — the volume is ours, not the user's.
                    tgt = max(GATE_PCT + 1, int(round(self.trims.get(mic, 100) * shade)))
                    if vol != tgt:
                        opens.append((sid, vol, tgt))
                elif mic in open_set:
                    if vol <= GATE_PCT:
                        # Still at the gate level -> we gated it; open to trim.
                        opens.append((sid, vol, self.trims.get(mic, 100)))
                    elif self.trims.get(mic) != vol:
                        # Already open: the LIVE volume is authoritative — the
                        # user may have just dragged it, and converging it
                        # back to the stored trim would stomp that drag.
                        # Record it as the new trim instead... unless it's a
                        # shadow level we set ourselves a moment ago (shadow
                        # just promoted): that one ramps up to the real trim.
                        if vol == max(GATE_PCT + 1, int(round(self.trims.get(mic, 100) * shade))):
                            opens.append((sid, vol, self.trims.get(mic, 100)))
                        else:
                            self.trims[mic] = vol
                            self.save_trims()
                else:
                    # Leaving open state: whatever the user set while open is
                    # their trim for next time (volume drags on a GATED mic
                    # are ignored by design — the gate owns that volume).
                    # A shadow-level volume is OURS, not a user trim.
                    if (vol > GATE_PCT and vol != max(
                            GATE_PCT + 1,
                            int(round(self.trims.get(mic, 100) * shade)))):
                        self.trims[mic] = vol
                        self.save_trims()
                    if vol != GATE_PCT:
                        closes.append((sid, vol, GATE_PCT))
            if not opens and not closes:
                # Still record the open set: on a no-op pass (e.g. first
                # apply with everything already at target) the UI's live-open
                # indicators must not stay blank.
                self.write_state()
                return
            # Every real gain move is logged: "who was at what and where we
            # sent it" is the ONLY way to see a volume fight (daemon vs
            # stream-restore vs UI) in the journal after the fact —
            # intermittent on/off chopping with no trail, 2026-10-06.
            for sid, v0, v1 in opens:
                log("gain: stream %s %d%% -> %d%% (open)" % (sid, v0, v1))
            for sid, v0, v1 in closes:
                log("gain: stream %s %d%% -> %d%% (gate)" % (sid, v0, v1))
            steps = max(1, int(self.cfg.get("ramp_steps", 4))) if ramp else 1
            dt = (self.cfg.get("crossfade_ms", 120) / 1000.0) / steps
            # Make before break: ramp the opening mics fully up, THEN ramp the
            # closing ones down — both carry the voice for ~crossfade_ms, which
            # is a brief overlap instead of a gap (the switcher's hard
            # retargets clipped words; that failure mode is gone by design).
            def ramp_all(rows):
                for i in range(1, steps + 1):
                    for sid, v0, v1 in rows:
                        set_stream_vol(sid, v0 + (v1 - v0) * i / steps)
                    if i < steps:
                        time.sleep(dt)
            ramp_all(opens)
            ramp_all(closes)
            self.write_state()

        def write_state(self):
            try:
                opens = []
                for g in self.groups:
                    opens.extend(g.open_mics())
                    opens.extend(g.shadow_mics())   # live (shaded) counts as open
                with open(STATE, "w") as f:
                    f.write("\n".join(opens) + "\n")
            except Exception:
                pass

        # True while any OPEN mic is hearing strong, user-grade SNR — the
        # discriminator between the user actually talking at a mic and
        # playback/vocals merely passing the output VAD.
        def _user_speaking(self, now):
            # "The user is speaking RIGHT NOW" for the gate calibrator. Uses
            # the same viable() test as mic selection (recent + user-grade SNR
            # + sustained past gate_speech_ms) so a single VAD-tripping click
            # or fan burst can never be banked as speech. viable() takes its
            # own lock — do not hold mt.lock around it.
            need_ms = self.cfg.get("gate_speech_ms", 300)
            for g in self.groups:
                for mic in g.open_mics():
                    mt = self.meters.get(mic)
                    if mt is None:
                        continue
                    if mt.viable(now, self.near_bar(mic), need_ms):
                        return True
            return False

        # ── gate auto-calibration (speech-relative, no absolute numbers) ──
        # Tracks the user's speech level at the chain output and keeps the
        # post-RNNoise level gate a RELATIVE margin below it. Absolute dBFS
        # thresholds don't transfer across mics/gains/rooms (explicit user
        # requirement 2026-10-06); the margin does. The pipewire.nix values
        # are cold-boot seeds this overrides after a few seconds of speech.
        def _gate_autofit(self, now):
            if not self.cfg.get("gate_autofit", True) or self.out_meter is None:
                return
            m = self.out_meter
            with m.lock:
                voiced = (now - m.last_voiced) <= m.grace_s
                since_voiced = now - m.last_voiced
                lvl = m.level
            if lvl > 0:
                db = lvl * 0.7 - 70.0  # meter level 0..100 maps -70..0 dBFS
                if voiced:
                    # Learn the speech level ONLY while an open mic hears
                    # user-grade SNR: vocal music bleeding through the
                    # speakers VAD-classifies as "speech" at -50ish and
                    # dragged the tracked level (and the gate) down with it
                    # (caught passively 2026-10-06). The user at a mic reads
                    # SNR 20-40; playback bleed reads ~1 — unambiguous.
                    if self._user_speaking(now):
                        # Slow EWMA: converges within seconds of real speech,
                        # follows the user's level, never chases silence.
                        self.speech_db = db if self.speech_db is None else (
                            0.98 * self.speech_db + 0.02 * db)
                        if self.gate_dirty == 0.0:
                            self.gate_dirty = now
                elif since_voiced > 5.0:
                    # NON-voiced audio LONG after any speech = gate leakage
                    # (fan residue clearing the current threshold). Track its
                    # ceiling: fast up (a leak is proof), slow decay (so one
                    # loud-fan day doesn't pin the gate up forever). The 5 s
                    # standoff is load-bearing: distant/garbled USER SPEECH
                    # also fails the VAD, and learning it as "noise" during a
                    # walk-away railed the threshold to 2.6 dB below the
                    # user's own voice (2026-10-06). Real speech always has
                    # voiced windows nearby; true fan residue has none.
                    #
                    # EXCEPT while media plays: speaker audio leaves AEC
                    # RESIDUAL on the chain output that is ALSO non-voiced and
                    # 5 s past speech — indistinguishable here from fan hiss.
                    # A YouTube video banked its residual as the noise floor,
                    # lifted the gate ~6 dB and hard-clipped the user's own
                    # speech afterwards (2026-10-09). Skip the noise update
                    # while the playback reference is (recently) live.
                    play_recent = False
                    if self.ref_meter is not None:
                        with self.ref_meter.lock:
                            play_recent = (now - self.ref_meter.last_voiced) <= (
                                self.ref_meter.grace_s
                                + float(self.cfg.get("echo_clear_ms", 400)) / 1000.0)
                    if not play_recent:
                        if self.noise_db is None:
                            self.noise_db = db
                        elif db > self.noise_db:
                            self.noise_db = 0.7 * self.noise_db + 0.3 * db
                        else:
                            self.noise_db = 0.995 * self.noise_db + 0.005 * db
                        if self.gate_dirty == 0.0:
                            self.gate_dirty = now
            # Persist the calibration ~60 s after it last changed, so a
            # reboot/rebuild resumes from it instead of an inaudible warm-up.
            if self.gate_dirty and (now - self.gate_dirty) > 60.0:
                self.save_gate()
            # Apply even when NOT currently voiced: lets the calibration LOADED
            # at startup take effect before the first word (no warm-up) and the
            # gate track a moving noise floor during pauses. Learning above
            # still requires voiced speech, so silence never moves the levels.
            if self.speech_db is None:
                return
            if (now - self.gate_at) < 5.0:
                return
            self.gate_at = now
            tgt = self.speech_db - float(self.cfg.get("gate_margin_db", 25.0))
            # Two-sided: far enough below speech to never clip it, but above
            # the measured residue ceiling so leaks can't trip consumer VADs.
            # The noise lift never comes within 6 dB of tracked speech: if
            # they really are that close, chopped speech is the worse failure
            # and the flashing indicator is the lesser evil.
            if self.noise_db is not None:
                lift = self.noise_db + float(self.cfg.get("gate_noise_headroom_db", 6.0))
                lift = min(lift, self.speech_db - 6.0)
                tgt = max(tgt, lift)
            tgt = max(float(self.cfg.get("gate_min_db", -60.0)),
                      min(float(self.cfg.get("gate_max_db", -35.0)), tgt))
            if self.gate_db is not None and abs(tgt - self.gate_db) < 2.0:
                return
            if self.gate_node is None:
                try:
                    out = run_out(["pw-dump"], timeout=10)
                    for obj in json.loads(out):
                        props = ((obj.get("info") or {}).get("props")) or {}
                        if props.get("node.name") == RN_SOURCE:
                            self.gate_node = obj["id"]
                            break
                except Exception:
                    return
            if self.gate_node is None:
                return
            lin = 10.0 ** (tgt / 20.0)
            try:
                r = subprocess.run(
                    ["pw-cli", "set-param", str(self.gate_node), "Props",
                     '{ params = [ "gate:Curve threshold (G)" %.6f ] }' % lin],
                    capture_output=True, text=True, timeout=5)
                # pw-cli exits 0 even for dead ids ("no global") — treat error
                # text as failure and re-resolve next pass (PipeWire restart).
                if r.returncode != 0 or "error" in (r.stdout + r.stderr).lower():
                    self.gate_node = None
                    return
            except Exception:
                self.gate_node = None
                return
            self.gate_db = tgt
            log("gate autofit: speech %.1f dB -> threshold %.1f dB"
                % (self.speech_db, tgt))

        # ── selection (per speech window, per group) ─────────────────────
        def on_meter_update(self):
            if not self.enabled():
                return
            with self.lock:
                now_ = time.monotonic()
                self._env_learn(now_)
                self._gate_autofit(now_)
                changed = False
                for g in self.groups:
                    if self._select_group(g):
                        changed = True
                if changed:
                    self.apply_gains()

        def _tier_best(self, mics, now, bar, viable_ms, cred=None):
            # bar: a number, or a callable(mic) -> per-mic bar (envelopes).
            for m in mics:
                if cred is not None and not cred(m):
                    continue
                mt = self.meters.get(m)
                b = bar(m) if callable(bar) else bar
                if mt is not None and mt.viable(now, b, viable_ms):
                    return True
            return False

        def _tier_all_dead(self, mics, now, hold_ms):
            live = [self.meters[m] for m in mics if m in self.meters]
            if not live:
                return False
            return all(mt.is_dead(now, hold_ms) for mt in live)

        def _select_group(self, g):
            """Returns True if the group's open tier changed."""
            now = time.monotonic()
            cfg = self.cfg
            if not g.tiers or not g.enabled:
                return False       # unticked group: no selection, gains stay gated
            open_dead = g.open_tier is not None and self._tier_all_dead(
                g.open_mics(), now, cfg["dead_hold_ms"])
            # Playback credibility (replaces the old blanket freeze): while
            # the speakers carry voice, a mic's evidence counts only if its
            # SNR beats that mic's LEARNED bleed profile by bleed_margin_db —
            # so an out-of-earshot mic (bleed ~0) switches freely even mid-
            # song, the mic you're talking straight into clears its bleed
            # easily, and a mic hearing ONLY the speakers sits at its bleed
            # and stays ineligible (the Discord-yank bug stays dead). A mic
            # with no profile yet (< ~12 s of sampled playback) is treated
            # as not-credible — identical to the old freeze, converging to
            # full through-playback switching as profiles fill in. A DEAD
            # open tier bypasses everything: failing over beats correctness.
            cred = None
            if (not open_dead and self.ref_meter is not None
                    and (now - self.ref_meter.last_voiced) * 1000.0
                        < cfg.get("echo_clear_ms", 400)):
                margin = cfg.get("bleed_margin_db", 8.0)
                def cred(m):
                    mt = self.meters.get(m)
                    if mt is None or self.bleed_n.get(m, 0) < 200:
                        return False
                    with mt.lock:
                        s = mt.snr_ewma
                    return s >= self.bleed.get(m, 0.0) + margin

            # ── shadow-open: never inaudible during a transition ─────────
            # Opening an extra mic costs a moment of dual pickup; staying
            # deaf costs WORDS. The instant the open tier stops hearing the
            # user strongly, the best other tier with any credible speech
            # evidence opens at full trim alongside it — the real handoff
            # decision (with all its damping) proceeds underneath, invisible
            # because audio already flows. A false alarm just lingers
            # shadow_linger_ms after the open tier proves strong again.
            shadow_changed = False
            open_true = g._tier_mics(g.open_tier) if g.open_tier is not None else []
            open_strong = self._tier_best(
                open_true, now,
                lambda m: self.near_bar(m) - cfg["stick_db"],
                cfg["viable_ms"])
            if open_strong:
                g.mismatch_since = 0.0
                if g.shadow_strong == 0.0:
                    g.shadow_strong = now
                if (g.shadow_tier is not None
                        and (now - g.shadow_strong) * 1000.0
                            >= cfg.get("shadow_linger_ms", 800)):
                    log("group '%s': shadow close (tier %s)" % (g.name, g.shadow_tier))
                    g.shadow_tier = None
                    shadow_changed = True
            else:
                g.shadow_strong = 0.0
                # Cooldown: no new shadow right after any switch/promote —
                # without it, inflated bars produced a shadow→promote→shadow
                # churn loop every ~3 s while the user sat still (2026-10-06).
                # Estimator fixed too; this is the belt to that braces.
                if (g.shadow_tier is None
                        and (now - g.last_switch) * 1000.0
                            >= cfg.get("shadow_cooldown_ms", 1500)):
                    cand = None
                    for p, mics in g.tiers:
                        if p == g.open_tier:
                            continue
                        if self._tier_best(mics, now, cfg["snr_min"],
                                           cfg["viable_ms"], cred):
                            cand = p
                            break
                    # The MISMATCH STATE (someone else hears you while the
                    # open mic doesn't catch you strongly) must SUSTAIN
                    # before the overlap opens: at-desk sentence starts pass
                    # through it for ~100 ms because the fallback mic's
                    # evidence matures just before the open mic's "strong"
                    # does — shadowing on the instant doubled the voice at
                    # every sentence when both mics were in range
                    # (2026-10-06). A real walk-away holds the state for as
                    # long as you're between mics.
                    if cand is None:
                        g.mismatch_since = 0.0
                    elif g.mismatch_since == 0.0:
                        g.mismatch_since = now
                    elif (now - g.mismatch_since) * 1000.0 >= cfg.get("shadow_ms", 300):
                        log("group '%s': shadow open (tier %s)" % (g.name, cand))
                        g.shadow_tier = cand
                        g.shadow_since = now
                        shadow_changed = True
                elif (g.shadow_tier is not None
                      and (now - g.shadow_since) * 1000.0
                          >= cfg.get("shadow_max_ms", 2500)):
                    # The overlap is a BRIDGE, not a state: its open condition
                    # (fallback merely viable) is looser than the switch
                    # condition (fallback near), so sitting in the acoustic
                    # in-between reached a stable both-mics-open equilibrium —
                    # permanently doubled voice at the desk (heard live
                    # 2026-10-06). Past the deadline the transition has had
                    # every chance: open mic still weak means the shadow has
                    # PROVEN itself — promote it outright and go single-mic.
                    log("group '%s': shadow promote (tier %s -> open)"
                        % (g.name, g.shadow_tier))
                    if g.open_tier is not None:
                        g.left_at[g.open_tier] = now
                    g.open_tier = g.shadow_tier
                    g.shadow_tier = None
                    g.pending = None
                    g.last_switch = now
                    shadow_changed = True

            def tier_near(p, mics):
                disc = cfg["stick_db"] if p == g.open_tier else 0.0
                return self._tier_best(mics, now,
                                       lambda m: self.near_bar(m) - disc,
                                       cfg["viable_ms"], cred)

            # Current voice SNR of a tier's best-hearing (credible) mic.
            def tier_snr(mics):
                best = 0.0
                for m in mics:
                    if cred is not None and not cred(m):
                        continue
                    mt = self.meters.get(m)
                    if mt is None:
                        continue
                    with mt.lock:
                        if (now - mt.last_voiced) <= mt.grace_s:
                            best = max(best, mt.snr_ewma)
                return best

            desired = None
            for p, mics in g.tiers:
                if tier_near(p, mics):
                    desired = p
                    break
            if desired is None:
                for p, mics in g.tiers:
                    if self._tier_best(mics, now, cfg["snr_min"], cfg["viable_ms"], cred):
                        desired = p
                        break
            dom = cfg.get("dominate_db", 8.0)
            # Priority and dominance MUST agree, with a hysteresis band
            # between their firing points, or they oscillate: with both mics
            # in range the priority rule pulled UP to the desk mic while
            # dominance pulled DOWN to the (slightly better-hearing) headset
            # — mid-sentence ping-pong, mangled speech (2026-10-06). An
            # up-move to a near preferred tier is therefore VETOED while the
            # open tier still hears you dominate_db/2 more clearly; the
            # down-move needs the full dominate_db. Between the two bands,
            # whoever is open stays open.
            # The veto deliberately ignores the voice-run grace window: the
            # instantaneous SNR reads 0 in every inter-sentence gap, and a
            # return fired through one such gap put the desk mic on-air
            # while the user was in another room — 2 s of dead air + a
            # promote/return oscillation that doubled the voice whenever
            # they faced away (2026-10-06). snr_ewma persists through
            # silence and self-corrects on the next heard speech, which is
            # exactly the memory the veto needs.
            def tier_snr_held(mics):
                best = 0.0
                for m in mics:
                    mt = self.meters.get(m)
                    if mt is None:
                        continue
                    with mt.lock:
                        best = max(best, mt.snr_ewma)
                return best

            # Symmetrically, the up-veto yields to absolute sufficiency: if
            # you're speaking COMFORTABLY into the preferred mic right now,
            # you get it back no matter how well the fallback still hears
            # you — with a worn headset the fallback ALWAYS hears you, and
            # an unconditional veto would lock you off the desk mic forever.
            if (desired is not None and g.open_tier is not None
                    and desired != g.open_tier):
                prios_ = [p for p, _ in g.tiers]
                des_mics = g._tier_mics(desired)
                des_immune = min((self.immune_bar(m) for m in des_mics),
                                 default=1e9)
                if (g.open_tier in prios_
                        and prios_.index(desired) < prios_.index(g.open_tier)
                        and tier_snr(des_mics) < des_immune
                        and tier_snr_held(open_true)
                            >= tier_snr_held(des_mics) + dom / 2.0):
                    desired = g.open_tier
            # Dominance: the open tier holding its (stick-discounted) bar is
            # not enough when another tier hears you FAR more clearly — a desk
            # mic catching you from across the room still scrapes "near"
            # while the headset on your head is the obvious right answer.
            # Highest-priority dominating tier wins. NB: compare against the
            # TRUE open tier only — open_mics() includes the shadow, which
            # would otherwise out-vote the very tier it belongs to.
            # ABSOLUTE SUFFICIENCY RULE: while the open tier hears you
            # comfortably (near_snr + dominate_immune_db), it is IMMUNE to
            # dominance — a headset on your head will always beat a desk mic
            # by 8 dB on a mere lean-back, and "best mic wins" would betray
            # the priority order constantly ("WAAAY too happy to switch to
            # arctis", 2026-10-06). Relative comparison is a tie-breaker for
            # the MARGINAL band only: comfortable -> priority wins outright,
            # truly weak -> normal down-switch, in between -> dominance may
            # pull to a far clearer mic (the stalled-walk-away case).
            immune = min((self.immune_bar(m) for m in open_true), default=1e9)
            dominated = False
            if desired == g.open_tier and desired is not None:
                osnr = tier_snr(open_true)
                if osnr < immune:
                    for p, mics in g.tiers:
                        if p == g.open_tier:
                            continue
                        if (tier_snr(mics) >= osnr + dom
                                and self._tier_best(mics, now, cfg["snr_min"],
                                                    cfg["viable_ms"], cred)):
                            desired = p
                            dominated = True
                            break
            if desired is None or desired == g.open_tier:
                g.pending = None
                return shadow_changed

            prios = [p for p, _ in g.tiers]
            oi = prios.index(g.open_tier) if g.open_tier in prios else len(prios)
            di = prios.index(desired)
            threshold = cfg["hysteresis_ms"] if di < oi else cfg["drop_ms"]
            # Anti-flap applies to DOWN moves only: it exists to stop two
            # borderline-live mics ping-ponging, but "walk out and come right
            # back" is a normal move and the return UP to the preferred mic
            # must never be penalised for it (4s returns, traced 2026-10-06).
            left = g.left_at.get(desired)
            if (di > oi and left is not None
                    and (now - left) * 1000.0 < cfg["flap_window_ms"]):
                threshold = max(threshold, cfg["flap_hold_ms"])
            # Returns UP to a tier we only just left are cheap to delay —
            # the fallback mic is CARRYING the voice the whole time — and
            # expensive to rush: a 200 ms twitch-return put the desk mic
            # on-air mid promote/return oscillation (2026-10-06). Demand a
            # sustained case, without the full down-flap penalty.
            if (di < oi and left is not None
                    and (now - left) * 1000.0 < cfg["flap_window_ms"]):
                threshold = max(threshold, cfg.get("return_hold_ms", 800))
            # A dominance call outranks the slow timers INCLUDING the flap
            # hold: an 8 dB sustained differential is itself the confirmation,
            # and every further ms is spent on the mic that's mangling you —
            # walking away mid-sentence lost whole phrases to the desk mic's
            # gated/garbled distant pickup (2026-10-06).
            if dominated:
                threshold = min(threshold, cfg.get("dominate_ms", 300))
            if open_dead:
                threshold = cfg["dead_cut_ms"]
            if (now - g.last_switch) * 1000.0 < cfg["settle_ms"]:
                return shadow_changed
            if g.pending != desired:
                g.pending = desired
                g.pending_since = now
                return shadow_changed
            if (now - g.pending_since) * 1000.0 < threshold:
                return shadow_changed
            if g.open_tier is not None:
                g.left_at[g.open_tier] = now
            log("group '%s': tier %s -> %s" % (g.name, g.open_tier, desired))
            g.open_tier = desired
            if g.shadow_tier == desired:
                g.shadow_tier = None   # promoted — it IS the open tier now
            g.pending = None
            g.last_switch = now
            return True

        # ── config / lifecycle ───────────────────────────────────────────
        def rebuild_groups(self):
            raw = self.cfg.get("groups") or []
            old = {g.idx: g for g in self.groups}
            self.groups = []
            for i, spec in enumerate(raw):
                g = old.get(i) or Group(i, "")
                g.idx = i
                g.name = spec.get("name") or ("Group %d" % (i + 1))
                g.enabled = bool(spec.get("enabled", True))
                g.set_mics(spec.get("mics") or [])
                if g.all_mics():
                    self.groups.append(g)

        def apply_state(self):
            with self.lock:
                self.cfg = load_config()
                self.rebuild_groups()
                en = self.enabled()
                if en and not self.was_enabled:
                    # Entering automix: single graph pin + stand the legacy
                    # switcher down (suspend remembers whether it was on).
                    subprocess.run([AUTOMIC_MUTATE, "suspend"], timeout=5,
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                    self.pin_graph()
                    subprocess.run(["pkill", "-USR1", "-f", "mix-sync-daemon.py"],
                                   stderr=subprocess.DEVNULL)
                elif not en and self.was_enabled:
                    # Leaving automix: open everything back to trims so the
                    # blend is sane, then hand the filter the preferred mic
                    # and give the legacy switcher back its say.
                    for g in self.groups:
                        g.open_tier = g.tiers[0][0] if g.tiers else None
                    self.apply_gains(ramp=False)
                    target = None
                    present = present_sources()
                    for g in self.groups:
                        for m in g.all_mics():
                            if m in present:
                                target = m
                                break
                        if target:
                            break
                    if target:
                        subprocess.run([SET_INPUT, target], timeout=5)
                    subprocess.run([AUTOMIC_MUTATE, "resume"], timeout=5,
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                    subprocess.run(["pkill", "-USR1", "-f", "mix-sync-daemon.py"],
                                   stderr=subprocess.DEVNULL)
                self.was_enabled = en
                self._sync_meters()
                if en:
                    self.pin_graph()
                    self.apply_gains()
                log("state: enabled=%s groups=%s open=%s"
                    % (en, [(g.name, g.tiers) for g in self.groups],
                       [(g.name, g.open_tier) for g in self.groups]))

        # Node add/remove: wrappers/streams may have (dis)appeared — re-gate
        # everything so a fresh stream never sits open by default, and make
        # sure the graph pin survived.
        def _on_node_event(self):
            with self.lock:
                if not self.enabled():
                    return
                self._sync_meters()
                self.pin_graph()
                self.apply_gains(ramp=False)

        def _schedule_verify(self):
            with self.lock:
                if self.verify_timer is not None:
                    self.verify_timer.cancel()
                self.verify_timer = threading.Timer(0.5, self._on_node_event)
                self.verify_timer.daemon = True
                self.verify_timer.start()

        def watch(self):
            try:
                proc = subprocess.Popen(["pactl", "subscribe"],
                                        stdout=subprocess.PIPE, text=True)
            except Exception as e:
                log("subscribe failed:", e)
                return
            for line in proc.stdout:
                if "on server" in line:
                    with self.lock:
                        if self.enabled():
                            self.pin_graph()
                    self._schedule_verify()
                elif " on source #" in line and ("'new'" in line or "'remove'" in line):
                    self._schedule_verify()
                elif " on source-output #" in line and "'change'" in line:
                    # A blend-stream volume drag: an OPEN mic's new volume is
                    # its trim. Debounced via the same one-shot timer.
                    self._schedule_verify()

        def reload_loop(self):
            while True:
                self.reload.wait()
                self.reload.clear()
                self.apply_state()

        def run(self):
            ensure_config()
            log("started; config", CONFIG)
            self.apply_state()
            threading.Thread(target=self.reload_loop, daemon=True).start()
            self._schedule_verify()
            self.watch()

    def main():
        ctrl = Controller()
        signal.signal(signal.SIGHUP, lambda *_: ctrl.reload.set())
        ctrl.run()

    if __name__ == "__main__":
        try:
            main()
        except KeyboardInterrupt:
            pass
  '';

  automix-daemon-sh = pkgs.writeShellScriptBin "audio-automix-daemon" ''
    # gawk: helpers this daemon execs (audio-list-blend-mics) must find awk
    # even under the bare systemd user PATH.
    export PATH="${pkgs.pulseaudio}/bin:${pkgs.pipewire}/bin:${pkgs.procps}/bin:${pkgs.gawk}/bin:$PATH"
    export AUTOMIX_VAD_METER="${vad-meter-sh}/bin/audio-vad-meter"
    export AUTOMIX_SET_INPUT="${rnnoise-set-input-sh}/bin/audio-rnnoise-set-input"
    export AUTOMIX_GET_INPUT="${rnnoise-current-input-sh}/bin/audio-rnnoise-current-input"
    export AUTOMIX_LIST_BLEND="${list-blend-mics-sh}/bin/audio-list-blend-mics"
    export AUTOMIX_AUTOMIC_MUTATE="${auto-mic-mutate-sh}/bin/audio-auto-mic-mutate"
    exec ${pkgs.python3}/bin/python ${automix-daemon-py}
  '';

  # ── Automix UI backend ──────────────────────────────────────────────────────
  # Emits:  enabled|<0|1>
  #         group|<idx>|<0|1 mixed-in>|<name>
  #         mic|<groupIdx>|<priority>|<node>
  #         open|<node>              (one per currently-open mic)
  automix-read-sh = pkgs.writeShellScriptBin "audio-automix-read" ''
    cfg=${automix-config-path}
    state="''${XDG_RUNTIME_DIR:-/tmp}/automix-open"
    if [ -f "$cfg" ]; then
      ${pkgs.jq}/bin/jq -r '
        "enabled|" + (if .enabled then "1" else "0" end),
        ((.groups // []) | to_entries[] |
          ("group|\(.key)|\(if .value.enabled == false then "0" else "1" end)|\(.value.name // ("Group " + ((.key + 1) | tostring)))"),
          (.key as $gi | (.value.mics // [])[] |
            "mic|\($gi)|\(.priority // 1)|\(.node)"))
      ' "$cfg" 2>/dev/null || echo "enabled|0"
    else
      echo "enabled|0"
    fi
    [ -f "$state" ] && ${pkgs.gnused}/bin/sed 's/^/open|/' "$state"
    exit 0
  '';

  # Mutations. All edits HUP the automix daemon (live apply) and poke the
  # mix-sync daemon (wrapper/delay policy may change with membership).
  #   toggle-enabled | set-enabled <1|0>
  #   group-add                        append empty group
  #   group-rename <idx> <name>
  #   group-toggle <idx>               tick/untick the group's mix participation
  #   group-remove <idx>               (members return to group 0)
  #   mic-toggle <node> [groupIdx]     add to group (default 0) / remove
  #   mic-move <node> <groupIdx>       move between groups (keeps priority)
  #   mic-priority <node> <prio>       set priority (>=1)
  automix-mutate-sh = pkgs.writeShellScriptBin "audio-automix-mutate" ''
    cfg=${automix-config-path}
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$cfg")"
    [ -f "$cfg" ] || echo '{"enabled":false,"groups":[{"name":"Group 1","mics":[]}]}' > "$cfg"
    jq=${pkgs.jq}/bin/jq
    cmd="$1"; a="$2"; b="$3"
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    case "$cmd" in
      toggle-enabled)
        "$jq" '.enabled = ((.enabled // false) | not)' "$cfg" > "$tmp" ;;
      set-enabled)
        "$jq" --argjson v "$([ "$a" = "1" ] && echo true || echo false)" \
          '.enabled = $v' "$cfg" > "$tmp" ;;
      group-add)
        "$jq" '.groups = ((.groups // []) + [{"name": ("Group " + (((.groups // []) | length) + 1 | tostring)), "mics": []}])' "$cfg" > "$tmp" ;;
      group-rename)
        "$jq" --argjson i "$a" --arg n "$b" \
          '.groups[$i].name = $n' "$cfg" > "$tmp" ;;
      group-toggle)
        # Tick/untick a group's mix participation (unticked = fully gated).
        # NB: jq's // treats false as empty, so `enabled // true` would stick
        # at false forever — compare explicitly instead.
        "$jq" --argjson i "$a" \
          '.groups[$i].enabled = (.groups[$i].enabled == false)' "$cfg" > "$tmp" ;;
      group-remove)
        # Members fall back into the first remaining group, so no mic is
        # silently dropped from the mix by deleting its card.
        "$jq" --argjson i "$a" '
          (.groups[$i].mics // []) as $orphans |
          .groups |= (del(.[$i]) // []) |
          if (.groups | length) == 0 then .groups = [{"name":"Group 1","mics":[]}] else . end |
          .groups[0].mics = ((.groups[0].mics // []) + $orphans)
        ' "$cfg" > "$tmp" ;;
      mic-toggle)
        gi="''${b:-0}"
        "$jq" --arg n "$a" --argjson gi "$gi" '
          if ([.groups[]?.mics[]? | select(.node == $n)] | length) > 0
          then .groups |= map(.mics |= map(select(.node != $n)))
          else .groups[$gi].mics = ((.groups[$gi].mics // []) + [{"node": $n, "priority": 1}])
          end' "$cfg" > "$tmp" ;;
      mic-move)
        "$jq" --arg n "$a" --argjson gi "$b" '
          ([.groups[]?.mics[]? | select(.node == $n)] | first) as $m |
          if $m == null then . else
            .groups |= map(.mics |= map(select(.node != $n))) |
            .groups[$gi].mics = ((.groups[$gi].mics // []) + [$m])
          end' "$cfg" > "$tmp" ;;
      mic-priority)
        "$jq" --arg n "$a" --argjson p "$b" '
          .groups |= map(.mics |= map(if .node == $n then .priority = ([$p, 1] | max) else . end))
        ' "$cfg" > "$tmp" ;;
      *) ${pkgs.coreutils}/bin/rm -f "$tmp"; echo "unknown command: $cmd" >&2; exit 1 ;;
    esac
    if [ -s "$tmp" ]; then ${pkgs.coreutils}/bin/mv "$tmp" "$cfg"; else ${pkgs.coreutils}/bin/rm -f "$tmp"; fi
    ${pkgs.procps}/bin/pkill -HUP -f automix-daemon.py 2>/dev/null || true
    ${pkgs.procps}/bin/pkill -USR1 -f mix-sync-daemon.py 2>/dev/null || true
    echo done
  '';

  # ── Cast audio time-sync ────────────────────────────────────────────────────
  # Auto-measures a Chromecast cast's end-to-end latency and delays the local MIX
  # outputs to match (via `delayed.<sink>` wrappers folded into combined_out by
  # mixset-slaves). Only meaningful while a cast is a member of the output MIX set.
  cast-sync-daemon-py = pkgs.writeText "cast-sync-daemon.py" (
    builtins.readFile ../../scripts/cast_sync_daemon.py
  );
  # gawk/gnugrep/coreutils are REQUIRED on PATH: the daemon shells out to
  # outdup-reload + mixset-slaves, which use bare `awk`/`grep`/`cat`. A systemd user
  # service's PATH is minimal (no gawk), so without this the reload silently no-ops
  # (mixset-slaves → empty → `outdup-reload` bails) and the delay never reaches the
  # combine — sync measures but never applies.
  cast-sync-daemon-sh = pkgs.writeShellScriptBin "audio-cast-sync-daemon" ''
    export PATH="${pkgs.pulseaudio}/bin:${pkgs.pipewire}/bin:${pkgs.gawk}/bin:${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:${outdup-reload-sh}/bin:${mixset-slaves-sh}/bin:$PATH"
    exec ${pkgs.python3}/bin/python ${cast-sync-daemon-py}
  '';

  # Manual sync trim, PER cast device (each Chromecast buffers differently). Targets
  # the currently-active cast (from its marker):
  #   audio-cast-sync-offset              → print this device's trim (seconds)
  #   audio-cast-sync-offset <delta>      → ADD delta (e.g. 0.05 / -0.05), print new
  #   audio-cast-sync-offset set <value>  → SET absolute trim, print new
  # The daemon re-reads it every tick, so changes are live.
  cast-sync-offset-sh = pkgs.writeShellScriptBin "audio-cast-sync-offset" ''
    marker="''${XDG_RUNTIME_DIR:-/tmp}/castaudio/active"
    device=$(${pkgs.gawk}/bin/awk -F= '$1=="device"{print $2}' "$marker" 2>/dev/null)
    if [ -z "$device" ]; then printf '0\n'; exit 0; fi   # no active cast → nothing to trim
    key=$(printf '%s' "$device" | ${pkgs.coreutils}/bin/tr -c 'A-Za-z0-9' '_')
    f="''${XDG_STATE_HOME:-$HOME/.local/state}/audio-cast-sync/offset-$key"
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
    cur=$(${pkgs.coreutils}/bin/cat "$f" 2>/dev/null || echo 0)
    if [ "''${1:-}" = set ]; then
      new=$(${pkgs.gawk}/bin/awk -v v="''${2:-0}" 'BEGIN{ if(v<-5)v=-5; if(v>15)v=15; printf "%.3f", v }')
      printf '%s\n' "$new" > "$f"; printf '%s\n' "$new"
    elif [ -n "''${1:-}" ]; then
      new=$(${pkgs.gawk}/bin/awk -v c="$cur" -v d="$1" \
        'BEGIN{ v=c+d; if(v<-5)v=-5; if(v>15)v=15; printf "%.3f", v }')
      printf '%s\n' "$new" > "$f"; printf '%s\n' "$new"
    else
      printf '%s\n' "''${cur:-0}"
    fi
  '';

  # The effective delay currently applied for the active cast (auto-measured + trim),
  # in seconds — what the per-card latency readout shows.
  cast-sync-delay-sh = pkgs.writeShellScriptBin "audio-cast-sync-delay" ''
    ${pkgs.coreutils}/bin/cat "''${XDG_STATE_HOME:-$HOME/.local/state}/audio-cast-sync/delay" 2>/dev/null || echo 0
  '';

  # Mic-based auto-calibrator: plays a chirp into the combine, records a mic that hears
  # BOTH the local speaker and the cast, cross-correlates the two arrivals, and nudges
  # the per-device trim until they line up. Needs an active cast + MIX on + a mic.
  cast-sync-calibrate-py = pkgs.writeText "cast-sync-calibrate.py" (
    builtins.readFile ../../scripts/cast_sync_calibrate.py
  );
  cast-sync-calibrate-sh = pkgs.writeShellScriptBin "audio-cast-sync-calibrate" ''
    export CAST_SYNC_OFFSET=${cast-sync-offset-sh}/bin/audio-cast-sync-offset
    export OUTDUP_RELOAD=${outdup-reload-sh}/bin/audio-outdup-reload
    export PATH="${pkgs.pulseaudio}/bin:$PATH"
    exec ${pkgs.python3.withPackages (ps: [ ps.numpy ])}/bin/python ${cast-sync-calibrate-py} "$@"
  '';

  # Sync is ON by default; a `disabled` marker turns it off. Inverted so that the
  # feature works out of the box (the common case: mix a cast → want it in sync).
  cast-sync-disabled-path = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/audio-cast-sync/disabled"'';

  cast-sync-status-sh = pkgs.writeShellScriptBin "audio-cast-sync-status" ''
    if [ -f ${cast-sync-disabled-path} ]; then echo off; else echo on; fi
  '';

  # Flip "delay local outputs to match the cast" on/off. Default = ON. OFF: write the
  # disabled marker, rebuild the combine WITHOUT the wrappers first (while they're
  # still alive → no gap), then stop the daemon (it tears the wrappers down). ON:
  # remove the marker, start the daemon, and fold the cast in now — the daemon then
  # spawns the delay wrappers and reloads again.
  cast-sync-toggle-sh = pkgs.writeShellScriptBin "audio-cast-sync-toggle" ''
    f=${cast-sync-disabled-path}
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
    if [ -f "$f" ]; then
      ${pkgs.coreutils}/bin/rm -f "$f"
      ${pkgs.systemd}/bin/systemctl --user start audio-cast-sync >/dev/null 2>&1 || true
      ${outdup-reload-sh}/bin/audio-outdup-reload >/dev/null 2>&1 || true
    else
      : > "$f"
      ${outdup-reload-sh}/bin/audio-outdup-reload >/dev/null 2>&1 || true
      ${pkgs.systemd}/bin/systemctl --user stop audio-cast-sync >/dev/null 2>&1 || true
    fi
    echo done
  '';

  # Global "recency of use" store for the unified audio device list. `touch <key>`
  # stamps a device (any kind — local sink/source, BT mac, cast name, tailnet
  # host:sink) with the current time; `list` prints `key<TAB>epoch` for the panel
  # to sort by. Keys never contain tabs.
  recency-sh = pkgs.writeShellScriptBin "audio-recency" ''
    f="''${XDG_STATE_HOME:-$HOME/.local/state}/qs-audio/recency"
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$f")"
    case "$1" in
      touch)
        key="$2"; [ -z "$key" ] && exit 0
        ts=$(${pkgs.coreutils}/bin/date +%s)
        tmp="$f.$$"
        { ${pkgs.gnugrep}/bin/grep -vF "$key	" "$f" 2>/dev/null; printf '%s\t%s\n' "$key" "$ts"; } > "$tmp" \
          && ${pkgs.coreutils}/bin/mv "$tmp" "$f"
        ;;
      list) ${pkgs.coreutils}/bin/cat "$f" 2>/dev/null ;;
      *) echo "usage: audio-recency touch <key> | list" >&2; exit 1 ;;
    esac
  '';

  # "net" if the default output is a tailnet-audio route proxy sink (its display
  # name is the remote DEVICE name, so the raw sink name is the only tell),
  # else "local" — drives the bar's network badge.
  default-sink-kind-sh = pkgs.writeShellScriptBin "audio-default-sink-kind" ''
    case "$(${pkgs.pulseaudio}/bin/pactl get-default-sink 2>/dev/null)" in
      tailnet-out-*) echo net ;;
      *) echo local ;;
    esac
  '';

  # Classify an output device:  audio-sink-icon-kind [sink-name]
  # (default sink when no arg). Prints one of:
  #   net | headphones | headset | hdmi | speaker
  # "speaker" is also the unknown/fallback class.
  sink-icon-kind-sh = pkgs.writeShellScriptBin "audio-sink-icon-kind" ''
    sink="''${1:-$(${pkgs.pulseaudio}/bin/pactl get-default-sink 2>/dev/null)}"
    case "$sink" in
      tailnet-out-*) echo net; exit 0 ;;
    esac
    ${pkgs.pulseaudio}/bin/pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk -v target="$sink" '
      function classify(    k, lp, lf, ld) {
        if (name != target || done) return
        done = 1
        k  = "speaker"
        lp = tolower(port); lf = tolower(ff); ld = tolower(desc)
        # Form factor / active port beat name heuristics; headset (has a mic)
        # before headphones so "headset" form factors do not fall through.
        if      (lf ~ /headset/   || lp ~ /headset/)                 k = "headset"
        else if (lp ~ /headphone/ || lf ~ /headphone/)               k = "headphones"
        else if (name ~ /^bluez_/ && ld ~ /head|bud|pods/)           k = "headphones"
        else if (lp ~ /hdmi|displayport/ || name ~ /hdmi/)           k = "hdmi"
        print k
      }
      /^Sink #/                { classify(); name = ""; desc = ""; port = ""; ff = "" }
      /^\tName:/               { name = $2 }
      /^\tDescription:/        { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/        { port = $3 }
      /device\.form_factor = / { match($0, /"[^"]*"/); ff = substr($0, RSTART+1, RLENGTH-2) }
      END { classify(); if (!done) print "speaker" }
    '
  '';

  # One-shot feed for the quickshell signal-flow graph. Everything the graph
  # can't derive from the stores it already has, read LIVE so the drawing can
  # never go stale against the real chain:
  #   outchain|<stage>,<stage>,...   filter stages of an applvl slot, in order
  #   inchain|<stage>,...            filter stages of the mic denoise chain
  #   aec|<present 0|1>|<on|off>     echo-cancel stage present / engaged
  #   sinkkind|<name>|<desc>|<kind>  per-sink device class (sink-icon-kind set)
  #   srckind|<name>|<desc>|<kind>   per-source class: headset|bt|webcam|phone|mic
  # Stage names come from the chain's Props control names ("<stage>:<control>"),
  # whose first-seen order follows the filter.graph declaration — control-less
  # builtins (copy/split) don't surface, which is fine for a flow display.
  graph-info-sh = pkgs.writeShellScriptBin "audio-graph-info" ''
    ${pkgs.pipewire}/bin/pw-dump 2>/dev/null | ${pkgs.jq}/bin/jq -r '
      def stages(nm):
        [ .[] | select(.info.props."node.name" == nm)
          | .info.params.Props[]? | select(.params) | .params
          | .[range(0; length; 2)]
          | select(type == "string" and contains(":")) | split(":")[0] ]
        | reduce .[] as $s ([]; if index($s) then . else . + [$s] end);
      "outchain|" + (stages("applvl.0") | join(",")),
      "inchain|"  + (stages("capture.rnnoise_source.filter") | join(",")),
      "aecnode|"  + (if any(.[]; .info.props."node.name"? == "aec_source")
                     then "1" else "0" end)
    ' | while IFS='|' read -r tag rest; do
      if [ "$tag" = "aecnode" ]; then
        echo "aec|$rest|$(${aec-status-sh}/bin/audio-aec-status)"
      else
        echo "$tag|$rest"
      fi
    done
    ${pkgs.pulseaudio}/bin/pactl list sinks 2>/dev/null | ${pkgs.gawk}/bin/awk '
      function flush(    k, lp, lf, ld) {
        if (name == "") return
        k  = "speaker"
        lp = tolower(port); lf = tolower(ff); ld = tolower(desc)
        if      (name ~ /^tailnet-out-/)                             k = "net"
        else if (lf ~ /headset/   || lp ~ /headset/)                 k = "headset"
        else if (lp ~ /headphone/ || lf ~ /headphone/)               k = "headphones"
        else if (name ~ /^bluez_/ && ld ~ /head|bud|pods/)           k = "headphones"
        else if (lp ~ /hdmi|displayport/ || name ~ /hdmi/)           k = "hdmi"
        print "sinkkind|" name "|" desc "|" k
      }
      /^Sink #/                { flush(); name = ""; desc = ""; port = ""; ff = "" }
      /^\tName:/               { name = $2 }
      /^\tDescription:/        { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/        { port = $3 }
      /device\.form_factor = / { match($0, /"[^"]*"/); ff = substr($0, RSTART+1, RLENGTH-2) }
      END { flush() }
    '
    ${pkgs.pulseaudio}/bin/pactl list sources 2>/dev/null | ${pkgs.gawk}/bin/awk '
      function flush(    k, lp, lf, ld) {
        if (name == "" || mon) return
        # The audio-mix-sync delayed.<mic> wrappers carry no device info of
        # their own — skip them; lookups strip the prefix and hit the real mic.
        if (name ~ /^delayed\./) return
        k  = "mic"
        lp = tolower(port); lf = tolower(ff); ld = tolower(desc)
        # "phone" must not swallow "microPHONE" descriptions
        if      (name ~ /^tailnet-mic-/ || lf ~ /phone/)             k = "phone"
        else if (lf ~ /headset/ || lp ~ /headset/ || ld ~ /headset/) k = "headset"
        else if (lf ~ /camera|webcam/ || ld ~ /camera|webcam/)       k = "webcam"
        else if (name ~ /^bluez_/)                                   k = "bt"
        print "srckind|" name "|" desc "|" k
      }
      /^Source #/              { flush(); name = ""; desc = ""; port = ""; ff = ""; mon = 0 }
      /^\tName:/               { name = $2 }
      /^\tDescription:/        { desc = substr($0, index($0, $2)) }
      /^\tActive Port:/        { port = $3 }
      /^\tMonitor of Sink:/    { if ($4 != "n/a") mon = 1 }
      /device\.form_factor = / { match($0, /"[^"]*"/); ff = substr($0, RSTART+1, RLENGTH-2) }
      END { flush() }
    '
    exit 0
  '';

  # ── Per-app OUTPUT balancing (loudness leveler + spike limiter) ─────────────
  # The daemon parks each running app on a free slot of the STATIC filter-chain
  # pool declared in pipewire.nix (applvl.0..N-1) by moving its sink-inputs, and
  # publishes the applied per-app gain for the bar. See balance_daemon.py.
  balance-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/audio-balance/config.json"'';

  balance-daemon-py = pkgs.writeText "balance-daemon.py" (builtins.readFile ./balance_daemon.py);

  balance-daemon-sh = pkgs.writeShellScriptBin "audio-balance-daemon" ''
    export PACTL=${pkgs.pulseaudio}/bin/pactl
    export PW_DUMP=${pkgs.pipewire}/bin/pw-dump
    export PW_CLI=${pkgs.pipewire}/bin/pw-cli
    export PAREC=${pkgs.pulseaudio}/bin/parec
    export MIC_INUSE=${mic-inuse-sh}/bin/audio-mic-inuse
    export DBUS_MONITOR=${pkgs.dbus}/bin/dbus-monitor
    export BUSCTL=${pkgs.systemd}/bin/busctl
    exec ${pkgs.python3}/bin/python ${balance-daemon-py} daemon
  '';

  # Emit balancing state as parseable lines:  output|<0|1>   input|<0|1>
  balance-read-sh = pkgs.writeShellScriptBin "audio-balance-read" ''
    cfg=${balance-config-path}
    if [ -f "$cfg" ]; then
      ${pkgs.jq}/bin/jq -r '
        "output|" + (if .output_enabled then "1" else "0" end),
        "input|"  + (if .input_enabled  then "1" else "0" end)
      ' "$cfg" 2>/dev/null || { echo "output|0"; echo "input|0"; }
    else
      echo "output|0"; echo "input|0"
    fi
    exit 0
  '';

  # Live applied gains from the daemon's balance.json, as parseable lines:
  #   range|<lo dB>|<hi dB>   (auto-calibrated arc display range, if known)
  #   duck|<enabled 0|1>|<active 0|1>|<dip dB>|<mic-trigger 0|1>   (ducking state)
  #   out|<gain%>|<offset%>|<sink-input#>,...|<gain dB>|<slot>|<fx preset or ->|<prio 0|1>|<dip dB>
  #   in|<gain%>|<mic node.name>
  balance-gains-sh = pkgs.writeShellScriptBin "audio-balance-gains" ''
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/qs-audio/balance.json"
    [ -f "$state" ] || exit 0
    ${pkgs.jq}/bin/jq -r '
      (if .range then "range|\(.range.lo)|\(.range.hi)" else empty end),
      (if .duck then "duck|" + (if .duck.enabled then "1" else "0" end)
                + "|" + (if .duck.active then "1" else "0" end)
                + "|\(.duck.db // 8)"
                + "|" + (if .duck.mic then "1" else "0" end) else empty end),
      (.output[]? | "out|\(.gain)|\(.offset // 100)|" + ((.ids // []) | map(tostring) | join(",")) + "|\(.gain_db // 0)|\(.slot // "")|\(.fx // "-")|\(.prio // 0)|\(.dip // 0)"),
      (.input[]?  | "in|\(.gain)|\(.key)")
    ' "$state" 2>/dev/null
    exit 0
  '';

  # Toggle balancing per side:  audio-balance-mutate <output|input> <toggle|1|0>
  balance-mutate-sh = pkgs.writeShellScriptBin "audio-balance-mutate" ''
    cfg=${balance-config-path}
    ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$cfg")"
    [ -f "$cfg" ] || echo '{"output_enabled":false,"input_enabled":false}' > "$cfg"
    side="$1"; cmd="$2"
    case "$side" in
      output) key=output_enabled ;;
      input)  key=input_enabled ;;
      *) echo "bad side: $side" >&2; exit 1 ;;
    esac
    jq=${pkgs.jq}/bin/jq
    tmp=$(${pkgs.coreutils}/bin/mktemp)
    case "$cmd" in
      toggle) "$jq" --arg k "$key" '.[$k] = ((.[$k] // false) | not)' "$cfg" > "$tmp" ;;
      1) "$jq" --arg k "$key" '.[$k] = true'  "$cfg" > "$tmp" ;;
      0) "$jq" --arg k "$key" '.[$k] = false' "$cfg" > "$tmp" ;;
      *) ${pkgs.coreutils}/bin/rm -f "$tmp"; echo "unknown command: $cmd" >&2; exit 1 ;;
    esac
    if [ -s "$tmp" ]; then ${pkgs.coreutils}/bin/mv "$tmp" "$cfg"; else ${pkgs.coreutils}/bin/rm -f "$tmp"; fi
    # Nudge the daemon to re-read config + reconcile now (event-driven).
    ${pkgs.procps}/bin/pkill -HUP -f balance-daemon.py 2>/dev/null || true
    echo done
  '';

  # Post-leveler per-app trim:  audio-balance-setvol <sink-input-id> <pct>
  # The gauge calls this when output balancing is ON. It sets the volume of the
  # slot's playback bridge (applvl.<n>.out), which is applied AFTER the leveler,
  # so the trim sticks instead of being normalised away. No-op if the stream is
  # not currently on a balance slot.
  balance-setvol-sh = pkgs.writeShellScriptBin "audio-balance-setvol" ''
    PATH=${pkgs.pulseaudio}/bin:${pkgs.gawk}/bin:$PATH
    id="$1"; pct="$2"; slot="$3"
    [ -z "$id" ] || [ -z "$pct" ] && exit 1
    # The caller (the panel gauge) usually already knows the slot from the
    # daemon's rows and passes it as $3 — this runs on every drag tick, so
    # skipping the stream→sink→slot re-resolution (two extra full pactl
    # dumps = two extra pulse clients per call) matters. Bare 2-arg calls
    # still resolve it themselves.
    if [ -z "$slot" ]; then
      # which sink INDEX is this stream on?
      sidx=$(pactl list sink-inputs | awk -v want="$id" '
        /^Sink Input #/ { cur=substr($3,2) }
        /^\tSink:/      { if (cur==want) { print $2; exit } }')
      [ -z "$sidx" ] && exit 0
      # index -> name; must be a balance slot
      slot=$(pactl list short sinks | awk -v i="$sidx" '$1==i {print $2}')
    fi
    case "$slot" in applvl.*|strmfx.*) ;; *) exit 0 ;; esac
    # find the slot's .out bridge sink-input and set its volume
    outid=$(pactl list sink-inputs | awk -v n="$slot.out" '
      /^Sink Input #/ { cur=substr($3,2) }
      /node\.name = / { if (index($0, "\"" n "\"")) { print cur; exit } }')
    [ -n "$outid" ] && pactl set-sink-input-volume "$outid" "$pct%"
    echo done
  '';

  # ── Voice-chat ducking ──────────────────────────────────────────────────────
  # Dips everything that isn't voice chat while someone is speaking. Detection
  # and the dipping itself live in the balance daemon (it is the single owner
  # of stream placement/volumes — see balance_daemon.py); this is just the
  # config CLI. Voice is detected on the voice app's own playback streams
  # (vesktop by default; per-user discordpeer.* bridges are picked up
  # automatically once the per-user split is active).
  #   audio-duck read              → enabled|<0|1>  level|<dB>  active|<0|1>
  #                                  prio|<app key> (one line per priority app)
  #   audio-duck toggle|1|0        → enable/disable ducking
  #   audio-duck set-level <dB>    → how many dB other audio dips (1-30), a
  #                                  true dB dip (chain duck-gain stage)
  #   audio-duck prio <id|key> [toggle|1|0]
  #                                → mark/unmark an app as a PRIORITY stream:
  #                                  priority streams trigger the ducking and
  #                                  are never ducked themselves. Numeric arg =
  #                                  sink-input id, resolved to its app key
  #                                  (same awk resolver as audio-streamfx).
  #   audio-duck mic [toggle|1|0]  → also trigger the duck from the USER'S OWN
  #                                  speech (rnnoise_source detector in the
  #                                  daemon), active only while a real app is
  #                                  capturing the mic (per audio-mic-users).
  #   audio-duck mic-level <dB>    → dip depth while the OWN-SPEECH trigger is
  #                                  hot (floors the adaptive/far-end depth;
  #                                  deeper by default — 15 dB).
  #   audio-duck mic-threshold <dB>
  #                                → own-speech gate sensitivity, given as dB
  #                                  below full scale (20-60, default 35 →
  #                                  -35 dBFS). HIGHER = less sensitive.
  #   audio-duck margin <dB>       → adaptive headroom: ducked audio sits this
  #                                  far below the call voices (default 1 —
  #                                  nearly imperceptible; 6+ is clearly heard).
  #   audio-duck adaptive [1|0|toggle]
  #                                → adaptive dip sizing vs fixed duck_db.
  duck-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/audio-duck/config.json"'';

  duck-sh = pkgs.writeShellScriptBin "audio-duck" ''
    PATH=${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:${pkgs.pulseaudio}/bin:${pkgs.gawk}/bin:$PATH
    cfg=${duck-config-path}
    case "''${1:-read}" in
      read)
        if [ -f "$cfg" ]; then
          jq -r '"enabled|" + (if .enabled then "1" else "0" end),
                 "level|\(.duck_db // 8)",
                 "adaptive|" + (if (.adaptive // true) then "1" else "0" end),
                 "margin|\(.margin_db // 1)",
                 "mic|" + (if (.mic_trigger // false) then "1" else "0" end),
                 "miclevel|\(.mic_duck_db // 15)",
                 "micthreshold|\((.mic_threshold_db // -35) | -.)",
                 ((.voice_apps // ["vesktop"])[] | "prio|" + ascii_downcase)' \
            "$cfg" 2>/dev/null \
            || { echo "enabled|0"; echo "level|8"; echo "adaptive|1"; echo "margin|1"; echo "mic|0"; echo "miclevel|15"; echo "micthreshold|35"; echo "prio|vesktop"; }
        else
          echo "enabled|0"; echo "level|8"; echo "adaptive|1"; echo "margin|1"; echo "mic|0"; echo "miclevel|15"; echo "micthreshold|35"; echo "prio|vesktop"
        fi
        state="''${XDG_STATE_HOME:-$HOME/.local/state}/qs-audio/balance.json"
        { [ -f "$state" ] && jq -r \
            '"active|" + (if .duck.active then "1" else "0" end)' \
            "$state" 2>/dev/null; } || echo "active|0"
        exit 0 ;;
      prio)
        target="''${2:-}"; action="''${3:-toggle}"
        [ -z "$target" ] && { echo "usage: audio-duck prio <sink-input-id|app-key> [toggle|1|0]" >&2; exit 1; }
        case "$target" in
          *[!0-9,]*) key=$(echo "$target" | tr '[:upper:]' '[:lower:]') ;;
          *)
            # numeric: resolve sink-input id(s) -> app key, mirroring the
            # daemon's app_key() (same resolver as audio-streamfx).
            key=""
            for id in $(echo "$target" | tr ',' ' '); do
              k=$(pactl list sink-inputs | awk -v want="$id" '
                /^Sink Input #/ { if (cur == want) exit; cur = substr($3, 2) }
                cur != want { next }
                /application\.process\.binary/ { split($0, a, "\""); bin  = a[2] }
                /application\.name/            { split($0, a, "\""); app  = a[2] }
                /node\.name = /                { split($0, a, "\""); node = a[2] }
                END {
                  if (tolower(node) ~ /^discordpeer\./) { print tolower(node); exit }
                  b = tolower(bin)
                  if (b == "" || b == "electron" || b == "chromium") {
                    k = (app != "") ? app : ((node != "") ? node : "")
                  } else k = b
                  print tolower(k)
                }')
              [ -n "$k" ] && { key="$k"; break; }
            done
            [ -z "$key" ] && { echo "could not resolve an app key from sink-input(s) $target" >&2; exit 1; }
            ;;
        esac
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        jq --arg k "$key" --arg act "$action" '
          .voice_apps = ((.voice_apps // ["vesktop"]) | map(ascii_downcase)) |
          .voice_apps = (if ($act == "1") or
                            ($act == "toggle" and ((.voice_apps | index($k)) == null))
                         then (.voice_apps + [$k] | unique)
                         else (.voice_apps - [$k]) end)
        ' "$cfg" > "$tmp"
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      toggle|1|0)
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        case "$1" in
          toggle) jq '.enabled = ((.enabled // false) | not)' "$cfg" > "$tmp" ;;
          1) jq '.enabled = true'  "$cfg" > "$tmp" ;;
          0) jq '.enabled = false' "$cfg" > "$tmp" ;;
        esac
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      mic)
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        case "''${2:-toggle}" in
          toggle) jq '.mic_trigger = ((.mic_trigger // false) | not)' "$cfg" > "$tmp" ;;
          1) jq '.mic_trigger = true'  "$cfg" > "$tmp" ;;
          0) jq '.mic_trigger = false' "$cfg" > "$tmp" ;;
          *) rm -f "$tmp"; echo "usage: audio-duck mic [toggle|1|0]" >&2; exit 1 ;;
        esac
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      set-level)
        db="''${2:-}"
        case "$db" in
          ""|*[!0-9]*) echo "usage: audio-duck set-level <1-30 dB>" >&2; exit 1 ;;
        esac
        [ "$db" -lt 1 ] && db=1
        [ "$db" -gt 30 ] && db=30
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        jq --argjson d "$db" '.duck_db = $d | del(.duck_pct)' "$cfg" > "$tmp"
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      margin)
        # Adaptive headroom: ducked audio is sized to sit this many dB below
        # the call voices. The old 1 dB default made far-end ducking
        # imperceptible whenever music/games were already quieter than the
        # voices ("ducking is broken", 2026-10-05) — raise for an audible dip.
        db="''${2:-}"
        case "$db" in
          ""|*[!0-9]*) echo "usage: audio-duck margin <0-20 dB>" >&2; exit 1 ;;
        esac
        [ "$db" -gt 20 ] && db=20
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        jq --argjson d "$db" '.margin_db = $d' "$cfg" > "$tmp"
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      adaptive)
        # adaptive 1|0|toggle — adaptive dip sizing vs the fixed duck_db dip.
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        case "''${2:-toggle}" in
          1) jq '.adaptive = true'  "$cfg" > "$tmp" ;;
          0) jq '.adaptive = false' "$cfg" > "$tmp" ;;
          *) jq '.adaptive = ((.adaptive // true) | not)' "$cfg" > "$tmp" ;;
        esac
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      mic-level)
        db="''${2:-}"
        case "$db" in
          ""|*[!0-9]*) echo "usage: audio-duck mic-level <1-30 dB>" >&2; exit 1 ;;
        esac
        [ "$db" -lt 1 ] && db=1
        [ "$db" -gt 30 ] && db=30
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        jq --argjson d "$db" '.mic_duck_db = $d' "$cfg" > "$tmp"
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      mic-threshold)
        # Stored negative (dBFS); entered positive as "dB below full scale".
        db="''${2:-}"
        case "$db" in
          ""|*[!0-9]*) echo "usage: audio-duck mic-threshold <20-60 dB below full scale>" >&2; exit 1 ;;
        esac
        [ "$db" -lt 20 ] && db=20
        [ "$db" -gt 60 ] && db=60
        mkdir -p "$(dirname "$cfg")"
        [ -f "$cfg" ] || echo '{"enabled":false,"duck_db":8}' > "$cfg"
        tmp=$(mktemp)
        jq --argjson d "$db" '.mic_threshold_db = -$d' "$cfg" > "$tmp"
        if [ -s "$tmp" ]; then mv "$tmp" "$cfg"; else rm -f "$tmp"; fi ;;
      *)
        echo "usage: audio-duck [read|toggle|1|0|set-level <dB>|mic [toggle|1|0]|mic-level <dB>|mic-threshold <dB>|prio <id|key> [toggle|1|0]]" >&2
        exit 1 ;;
    esac
    # Nudge the daemon to re-read config + reconcile now (event-driven).
    pkill -HUP -f balance-daemon.py 2>/dev/null || true
    echo done
  '';

  # ── Per-stream FX presets ───────────────────────────────────────────────────
  # Pin a specific app's output streams onto one of the static strmfx.<preset>
  # filter sinks (99-stream-fx in pipewire.nix) — e.g. voice-clarity on a
  # Discord call. Rules are per APP KEY (same derivation as the daemon's
  # app_key(): lowercased binary, or the app/node name for the shared
  # electron/chromium launcher) so they survive stream restarts; the balance
  # daemon applies them (it owns all sink-input placement — see
  # balance_daemon.py) whether or not balancing is enabled.
  #   audio-streamfx read                       → "<app key>|<preset>" lines
  #   audio-streamfx presets                    → "<preset>|<label>" lines
  #   audio-streamfx <id|key> <preset|off|cycle>  (numeric arg = sink-input id,
  #                                              resolved to its app key)
  # cycle order: off → voice → bass → off; the resulting preset is echoed.
  streamfx-sh = pkgs.writeShellScriptBin "audio-streamfx" ''
    PATH=${pkgs.pulseaudio}/bin:${pkgs.gawk}/bin:${pkgs.jq}/bin:${pkgs.coreutils}/bin:${pkgs.procps}/bin:$PATH
    rules="''${XDG_CONFIG_HOME:-$HOME/.config}/audio-streamfx/rules.json"
    presets="voice bass"

    case "''${1:-}" in
      presets)
        echo "voice|voice clarity"
        echo "bass|bass boost"
        exit 0 ;;
      read)
        [ -f "$rules" ] && jq -r 'to_entries[] | "\(.key)|\(.value)"' "$rules" 2>/dev/null
        exit 0 ;;
      "")
        echo "usage: audio-streamfx <sink-input-id|app-key> <voice|bass|off|cycle> | read | presets" >&2
        exit 1 ;;
    esac

    target="$1"; action="''${2:-cycle}"
    case "$target" in
      # numeric (or comma-separated) = sink-input id(s) from a gauge; resolve
      # the daemon's app key from stream properties (binary unless it's the
      # shared electron/chromium launcher, then the app/node name — MUST
      # mirror app_key() in balance_daemon.py or a rule set from the UI would
      # never match). The gauge keeps VANISHED streams visible for a 60s
      # age-out window, so its id list can contain dead ids that resolve to
      # nothing — try each id until one yields a real key, and refuse to
      # write a rule otherwise (a bad key like "app" pins nothing and the
      # switch just snaps back).
      *[!0-9,]*) key=$(echo "$target" | tr '[:upper:]' '[:lower:]') ;;
      *)
        key=""
        for id in $(echo "$target" | tr ',' ' '); do
          k=$(pactl list sink-inputs | awk -v want="$id" '
            /^Sink Input #/ { if (cur == want) exit; cur = substr($3, 2) }
            cur != want { next }
            /application\.process\.binary/ { split($0, a, "\""); bin  = a[2] }
            /application\.name/            { split($0, a, "\""); app  = a[2] }
            /node\.name = /                { split($0, a, "\""); node = a[2] }
            END {
              # per-user Discord bridge streams key on node.name (their owning
              # binary is pipewire-pulse — every participant would collide).
              if (tolower(node) ~ /^discordpeer\./) { print tolower(node); exit }
              b = tolower(bin)
              if (b == "" || b == "electron" || b == "chromium") {
                k = (app != "") ? app : ((node != "") ? node : "")
              } else k = b
              print tolower(k)
            }')
          [ -n "$k" ] && { key="$k"; break; }
        done
        [ -z "$key" ] && { echo "could not resolve an app key from sink-input(s) $target" >&2; exit 1; }
        ;;
    esac

    mkdir -p "$(dirname "$rules")"
    [ -f "$rules" ] || echo '{}' > "$rules"
    current=$(jq -r --arg k "$key" '.[$k] // "off"' "$rules" 2>/dev/null || echo off)

    if [ "$action" = "cycle" ]; then
      next=off
      prev=off
      for p in $presets; do
        if [ "$current" = "$prev" ]; then next="$p"; break; fi
        prev="$p"
      done
      # current was the last preset (or unknown) → next stays off
      action="$next"
    fi

    tmp=$(mktemp)
    case "$action" in
      off) jq --arg k "$key" 'del(.[$k])' "$rules" > "$tmp" ;;
      voice|bass) jq --arg k "$key" --arg v "$action" '.[$k] = $v' "$rules" > "$tmp" ;;
      *) rm -f "$tmp"; echo "unknown preset: $action" >&2; exit 1 ;;
    esac
    if [ -s "$tmp" ]; then mv "$tmp" "$rules"; else rm -f "$tmp"; fi
    # Nudge the daemon to apply the rules now (event-driven).
    pkill -HUP -f balance-daemon.py 2>/dev/null || true
    echo "$action"
  '';

  # Return a Bluetooth headset to A2DP once its mic goes idle. WirePlumber's
  # headset-profile autoswitch is disabled (see pipewire.nix), so a BT card only
  # enters HFP/HSP when switched MANUALLY — but a card can still be left stranded
  # there (low-quality output) after whatever used the mic goes away. This daemon
  # watches pactl events and, whenever a bluez card is in a headset profile with
  # its mic source fully suspended (no active capture), flips it back to A2DP. An
  # in-progress call keeps the source RUNNING, so it's never cut off.
  bt-mic-release-sh = pkgs.writeShellScriptBin "audio-bt-mic-release" ''
    set -uo pipefail
    pactl=${pkgs.pulseaudio}/bin/pactl
    jq=${pkgs.jq}/bin/jq
    head=${pkgs.coreutils}/bin/head
    sleep=${pkgs.coreutils}/bin/sleep

    release_idle() {
      "$pactl" -f json list cards 2>/dev/null \
        | "$jq" -r '.[] | select(.name | startswith("bluez_card."))
                        | select(.active_profile | test("head|hfp|hsp"; "i"))
                        | .name' \
        | while read -r card; do
            [ -n "$card" ] || continue
            mac=''${card#bluez_card.}

            # This card's mic source (bluez_input.<mac>) and its state. Source
            # names use ':' in the MAC, card names use '_' — normalise both.
            state=$("$pactl" -f json list sources 2>/dev/null \
              | "$jq" -r --arg n "bluez_input.$mac" \
                  '.[] | select((.name | gsub(":";"_")) == $n) | .state' \
              | "$head" -n1)

            # Only release once the mic has fully suspended — RUNNING/IDLE means
            # something may still be capturing (e.g. a live call). Empty = the
            # source is already gone, also safe to release.
            case "$state" in
              RUNNING|IDLE) continue ;;
            esac

            # Prefer a plain, available a2dp-sink profile for this card.
            a2dp=$("$pactl" -f json list cards 2>/dev/null \
              | "$jq" -r --arg c "$card" \
                  '.[] | select(.name == $c) | .profiles | to_entries
                   | map(select(.key | startswith("a2dp-sink")))
                   | map(select(.value.available != "no"))
                   | (map(select(.key == "a2dp-sink")) + .) | .[0].key // empty')
            [ -n "$a2dp" ] || continue

            "$pactl" set-card-profile "$card" "$a2dp" || true
            echo "[bt-mic-release] $card -> $a2dp"
          done
    }

    release_idle

    # Event-driven: react to card/source/recording-client changes; a short settle
    # delay lets PipeWire suspend the freed source before we re-check.
    "$pactl" subscribe 2>/dev/null | while read -r ev; do
      case "$ev" in
        *"on card"*|*"on source"*|*"on source-output"*)
          "$sleep" 0.6
          release_idle
          ;;
      esac
    done
  '';

  tools = [
    bt-mic-release-sh
    internal-node-sh
    balance-daemon-sh
    balance-read-sh
    balance-gains-sh
    balance-mutate-sh
    balance-setvol-sh
    duck-sh
    streamfx-sh
    bt-audio-connect-sh
    recency-sh
    default-sink-kind-sh
    sink-icon-kind-sh
    graph-info-sh
    list-sinks-sh
    list-sources-sh
    list-sink-inputs-sh
    list-dup-sinks-sh
    list-blend-mics-sh
    default-display-name-sh
    rnnoise-current-input-sh
    rnnoise-set-input-sh
    rnnoise-set-filter-sh
    rnnoise-toggle-sh
    rnnoise-status-sh
    aec-set-sh
    aec-status-sh
    aec-auto-daemon-sh
    micblend-status-sh
    micblend-set-sh
    micblend-toggle-sh
    outdup-status-sh
    outdup-toggle-sh
    outdup-reload-sh
    mixset-read-sh
    mixset-mutate-sh
    mixset-slaves-sh
    usb-headroom-set-sh
    usb-headroom-status-sh
    audio-xrun-guard-sh
    xrun-guard-status-sh
    xrun-guard-toggle-sh
    mic-inuse-sh
    mic-users-sh
    level-meter-sh
    vad-meter-sh
    auto-mic-daemon-sh
    auto-mic-read-sh
    auto-mic-mutate-sh
    automix-daemon-sh
    automix-read-sh
    automix-mutate-sh
    mix-sync-daemon-sh
    cast-sync-daemon-sh
    cast-sync-status-sh
    cast-sync-toggle-sh
    cast-sync-offset-sh
    cast-sync-delay-sh
    cast-sync-calibrate-sh
  ];

  # Human-facing dispatcher: `audioctl rnnoise-toggle`, `audioctl list-sinks`,
  # `audioctl headroom-set 512`... Every subcommand is also directly on PATH
  # as `audio-<subcommand>`.
  audioctl = pkgs.writeShellScriptBin "audioctl" ''
    if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "help" ]; then
      echo "usage: audioctl <command> [args]"
      echo "commands:"
      IFS=: read -ra dirs <<< "$PATH"
      for d in "''${dirs[@]}"; do
        [ -d "$d" ] && ls "$d" 2>/dev/null
      done | sed -n 's/^audio-/  /p' | sort -u
      exit 0
    fi
    cmd="audio-$1"; shift
    exec "$cmd" "$@"
  '';
in
rec {
  # Individual script derivations, for wiring into services etc.
  # internal-node-sh is exported so OTHER modules (e.g. guest-gaming.nix)
  # can apply the one canonical internal-node filter instead of keeping
  # their own copy of the mask.
  inherit
    bt-mic-release-sh
    audio-xrun-guard-sh
    auto-mic-daemon-sh
    automix-daemon-sh
    aec-auto-daemon-sh
    mix-sync-daemon-sh
    cast-sync-daemon-sh
    balance-daemon-sh
    internal-node-sh
    ;

  # Everything on PATH: audio-* tools + the audioctl dispatcher.
  audio-tools = pkgs.symlinkJoin {
    name = "audio-tools";
    paths = tools ++ [ audioctl ];
  };
}
