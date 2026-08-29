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
        # combined_out (output duplicator) is represented by the MIX toggle,
        # not a device row.
        if (name == "combined_out") return
        # tailnet-audio mic-donation plumbing: a null-sink whose monitor becomes a
        # donated mic source. The phone-SPEAKER sink is tailnet-out-<host> and DOES
        # belong here (a usable output = your phone).
        if (name ~ /^tailnet-mic-/) return
        # Local PROXY sinks for a REMOTE output are represented by their remote
        # device row (tailnet/cast), so hide the proxy to avoid a duplicate: the
        # route proxy carries tailnet_audio.route, and cast proxies are cast*_ .
        if (is_route) return
        if (name ~ /^castaudio_/ || name ~ /^cast_/) return
        # cast-sync delay wrappers (delayed.<sink> + bare pw-loopback nodes) are
        # internal plumbing: they interpose a fixed delay in front of a real sink
        # to time-align it with a cast, and are represented by that real sink.
        if (name ~ /^delayed\./ || name ~ /^pw-loopback/) return
        # snd_aloop loopback ("Loopback Analog Stereo", guest-gaming plumbing)
        # is internal, never user-selectable — same rule as list-sources.
        if (name ~ /platform-snd_aloop/) return
        # applvl.* = the per-app balance pool (internal leveler sinks).
        if (name ~ /^applvl\./) return
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
        if (name == "" || name ~ /\.monitor$/ || name == "rnnoise_source" || name == "combined_mics") return
        # our own virtual plumbing: audio-mix-sync delay wrappers (delayed.<mic>
        # + any bare pw-loopback nodes) and the snd_aloop loopback device
        # ("Loopback Analog Stereo", guest-gaming plumbing) are internal,
        # never user-selectable
        if (name ~ /^delayed\./ || name ~ /^pw-loopback/) return
        if (name ~ /platform-snd_aloop/) return
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
      [ -z "$prev" ] && prev=$(pactl list short sinks 2>/dev/null | awk '
        $2 ~ /^(alsa_output|bluez_output)/ && $2 !~ /snd_aloop/ { print $2; exit }')
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
    present=$(pactl list short sinks 2>/dev/null | awk '
      $2 != "combined_out" && $2 !~ /platform-snd_aloop/ && $2 !~ /^applvl\./ { print $2 }')
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
    pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qxF "$safe" || \
      safe=$(pactl list short sinks 2>/dev/null | awk '
        $2 ~ /^(alsa_output|bluez_output)/ && $2 !~ /snd_aloop/ { print $2; exit }')
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
      # snd_aloop and the applvl balance pool are excluded from the combine
      # slaves; drop them here too so internal plumbing never grows a mixer row.
      function emit() { if (name != "" && name !~ /platform-snd_aloop/ && name !~ /^applvl\./) printf "%s|%s|%s\n", idx, name, display_name(port, alsa_card, alsa_device, desc) }
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

  # Point the filter's capture at a specific hardware mic. The filter capture
  # (capture.rnnoise_source) is a passive stream that does NOT auto-follow the
  # default once rnnoise_source itself is the default, so we retarget it
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
    state="$XDG_RUNTIME_DIR/qs-usb-headroom"

    cur() {
      c=$(cat "$state" 2>/dev/null)
      case "$c" in "" | *[!0-9]*) echo 0 ;; *) echo "$c" ;; esac
    }

    apply() {
      ${pkgs.pipewire}/bin/pw-dump 2>/dev/null \
        | ${pkgs.jq}/bin/jq '.[] | select((.info.props["node.name"] // "") | startswith("alsa_output.usb-")) | .id' \
        | while read -r id; do
            ${pkgs.pipewire}/bin/pw-cli set-param "$id" Props \
              "{ params = [ \"api.alsa.headroom\" $1 ] }" >/dev/null 2>&1 || true
          done
      printf '%s\n' "$1" > "$state"
    }

    # awk emits a line whenever a USB sink's ERR (xrun) count increases; the
    # column index is taken from pw-top's own header line rather than
    # hard-coded, because the layout varies between pipewire versions (this
    # one has W/Q and B/Q as separate columns, so ERR is field 9 — reading a
    # fixed field 8 picked up the per-cycle load ratio and fired constantly).
    # read -t turns 5 xrun-free minutes into a decay step.
    ${pkgs.pipewire}/bin/pw-top -b 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '
          $1 == "S" && $2 == "ID" {
            for (i = 1; i <= NF; i++) if ($i == "ERR") erridx = i
            next
          }
          erridx && $NF ~ /^alsa_output\.usb-/ {
            if ($NF in last && $erridx > last[$NF]) { print "x"; fflush() }
            last[$NF] = $erridx
          }' \
      | {
        last_bump=0
        while :; do
          ret=0
          read -r -t 300 _ || ret=$?
          if [ "$ret" -eq 0 ]; then
            now=$(date +%s)
            [ $((now - last_bump)) -lt 5 ] && continue
            last_bump=$now
            c=$(cur)
            if [ "$c" -lt 256 ]; then apply 256
            elif [ "$c" -lt 2048 ]; then apply $((c * 2))
            fi
          elif [ "$ret" -gt 128 ]; then
            c=$(cur)
            [ "$c" -eq 0 ] && continue
            n=$((c / 2)); [ "$n" -lt 256 ] && n=0
            apply "$n"
          else
            break     # pw-top went away (pipewire restart) — service restarts us
          fi
        done
      }
  '';

  # Guard on/off = whether the user service runs. The flag file makes the
  # choice stick across logins (the unit's ConditionPathExists checks it).
  xrun-guard-status-sh = pkgs.writeShellScriptBin "audio-xrun-guard-status" ''
    if ${pkgs.systemd}/bin/systemctl --user is-active -q audio-xrun-guard 2>/dev/null; then
      echo on
    else
      echo off
    fi
  '';

  xrun-guard-toggle-sh = pkgs.writeShellScriptBin "audio-xrun-guard-toggle" ''
    flag="''${XDG_CONFIG_HOME:-$HOME/.config}/qs-audio-xrun-guard-enabled"
    if ${pkgs.systemd}/bin/systemctl --user is-active -q audio-xrun-guard 2>/dev/null; then
      ${pkgs.systemd}/bin/systemctl --user stop audio-xrun-guard
      rm -f "$flag"
    else
      touch "$flag"
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
      # ...and resume single-mic duty (re-evaluate meters + feed belief).
      ${pkgs.procps}/bin/pkill -HUP -f auto-mic-daemon.py 2>/dev/null || true
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
    # "Source:" index into the mic behind it.
    sources=$(pactl list sources | awk '
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
    pactl list source-outputs | awk -v SRC="$sources" '
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
  # Trust model: existence comes from the kernel fd table + server-side PipeWire
  # topology, and FILTERING decisions use the kernel's view (the connected
  # source's monitor flag, and each holder's real /proc/PID/exe) — never the
  # client-set application.name / node.name / stream.monitor, which a process
  # can spoof. The advertised name is shown in the list purely for readability;
  # the exe (kernel truth) is what the UI reveals on hover. Defeated only by
  # root/kernel-level access, which is out of scope.
  mic-users-sh = pkgs.writeShellScriptBin "audio-mic-users" ''
    # Field separator for the awk→read handoff. Must be NON-whitespace: a tab
    # would be treated as IFS-whitespace and collapse empty fields, shifting
    # columns. 0x1f (unit separator) never appears in the data.
    SEP="$(printf '\037')"

    # Source indices that are playback monitors (NOT real mics), from the
    # server-side topology — not the spoofable client `stream.monitor` flag.
    monitors=$(pactl list sources 2>/dev/null | awk '
      /^Source #/                 { idx = substr($2, 2) }
      /^[[:space:]]*Name:/        { if ($2 ~ /\.monitor$/) print idx }
      /Monitor of Sink:/          { if ($0 !~ /n\/a/) print idx }
    ' | sort -u)

    is_monitor() {
      for m in $monitors; do [ "$m" = "$1" ] && return 0; done
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
        is_monitor "$src" && continue
        # Our own bar level meter (qs-mic-level) and per-mic VAD taps (qs-vad) —
        # never count them as mic users.
        [ "$appname" = "qs-mic-level" ] && continue
        [ "$appname" = "qs-vad" ] && continue
        # The RNNoise filter's own passive capture: a server-side filter node
        # has no Client (a real pulse/pipewire app always does, and can't fake
        # "n/a"), so this can't be spoofed by naming a stream capture.rnnoise_source.
        [ "$nodename" = "capture.rnnoise_source" ] && [ "$client" = "n/a" ] && continue
        # The mic combiner's per-mic capture streams (see combined_mics in
        # flakes/audio/pipewire.nix) — server-side too, same no-Client rule. Prefix
        # match because PipeWire may uniquify duplicate stream node names.
        case "$nodename" in capture.combined_mics*)
          [ "$client" = "n/a" ] && continue ;;
        esac
        # (tailnet-audio donated mics are plain pipe-source nodes with no internal
        # capture stream, so they need no exclusion here — they behave exactly
        # like a hardware mic and are counted in-use only when a real app captures.)
        # The screen recorder's always-on mic capture (replay buffer). It is
        # always listening by design, so it shouldn't read as an app actively
        # using the mic — but only skip it when it's PROVABLY the real recorder
        # (cgroup + exe), so nothing can hide behind its name. gsr names its mic
        # node "gsr-default_input"; its default_output capture is a monitor and
        # is already dropped by is_monitor above.
        case "$nodename" in gsr-*)
          is_replay_gsr "$pid" && continue ;;
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
      | ${vad-python}/bin/python ${vad-meter-py} "$agg"
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
  # Routing reuses the existing rnnoise plumbing: when the noise-cancel virtual
  # source is the default (denoise on), it retargets capture.rnnoise_source for a
  # seamless swap; otherwise (denoise off) it sets the default source directly.
  # So auto-switch works whether or not denoising is on.
  #
  # Config: $XDG_CONFIG_HOME/auto-mic/config.json (auto-created, disabled):
  #   { "enabled": true,
  #     "candidates": ["alsa_input.usb-Blue...", "alsa_input.usb-SteelSeries..."],
  #     "snr_min": 6, "viable_ms": 180, "grace_ms": 150, "hysteresis_ms": 350 }
  # candidates are source node.names, highest priority first.
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
        names = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                n = parts[1]
                if (n != RN_SOURCE and n != "combined_mics"
                        and not n.endswith(".monitor")
                        and not n.startswith("delayed.")      # mix-sync wrappers
                        and not n.startswith("pw-loopback")
                        and not n.startswith("tailnet-")       # network mic proxies
                        and "platform-snd_aloop" not in n):   # (consume/donation) — never a VAD candidate; guest plumbing
                    names.append(n)
        return names

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
            self.active_mic = None  # real mic currently feeding the filter
            self.pending = None
            self.pending_since = 0.0
            self.last_switch = 0.0
            self.left_at = {}       # mic -> monotonic when we last switched AWAY from it
            self.verify_at = 0.0    # last belief-vs-reality feed check
            self.verify_timer = None  # debounce for node-lifecycle feed checks
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
            if (self.active_mic in self.meters
                    and self.meters[self.active_mic].is_dead(now, cfg["dead_hold_ms"])):
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
                elif " on source #" in line and ("'new'" in line or "'remove'" in line):
                    # NB: " on source #" — a bare " on source" also matches
                    # "on source-output", i.e. every app stream open/close.
                    self._schedule_verify()      # device appeared/vanished

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
            self._schedule_verify()   # cover nodes that appear before subscribe attaches
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
        # $name is "1" or "0" — used by the MIX toggle to force auto off
        # (blend and auto-switch are mutually exclusive routing modes).
        "$jq" --argjson v "$([ "$name" = "1" ] && echo true || echo false)" \
          '.enabled = $v' "$cfg" > "$tmp" ;;
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
    trap "rm -f $titlesfile $namesfile" EXIT

    hyprctl clients -j 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[] | [(.pid|tostring), .title] | join("\u0001")' \
      > "$titlesfile" 2>/dev/null || true

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

    pactl list sink-inputs | awk -v tf="$titlesfile" -v nf="$namesfile" '
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
      }
      # The output duplicator per-sink playback streams (from the combine
      # sink the MIX toggle loads on demand) are not apps — they get their
      # own rows in the dup-sink mixer of the popup instead.
      function emit() {
        # applvl.<n>.out are the balance-pool bridge streams (see balance_daemon),
        # not apps — hide them or they show as phantom "Unknown" gauges.
        if (id == "" || nodename ~ /^output\.combined_out/ || nodename ~ /^applvl\./) return
        title = (pid in titles) ? titles[pid] : ""
        if (pid in enames) name = enames[pid]
        printf "%s|%s|%s|%s|%s|%s|%s\n", id, name, vol, muted, binary, corked, title
      }
      /^Sink Input #/ {
        emit()
        id = substr($3, 2); name = "Unknown"; vol = 100; muted = 0; binary = ""; pid = ""; nodename = ""; corked = 0
      }
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
                mics = real_mics()
                chosen = mix_set_sources()
                if chosen:                         # non-empty = blend only these
                    mics = [m for m in mics if m in chosen]
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

  # ── Per-app OUTPUT balancing (loudness leveler + spike limiter) ─────────────
  # The daemon parks each running app on a free slot of the STATIC filter-chain
  # pool declared in pipewire.nix (applvl.0..N-1) by moving its sink-inputs, and
  # publishes the applied per-app gain for the bar. See balance_daemon.py.
  balance-config-path = ''"''${XDG_CONFIG_HOME:-$HOME/.config}/audio-balance/config.json"'';

  balance-daemon-py = pkgs.writeText "balance-daemon.py" (builtins.readFile ./balance_daemon.py);

  balance-daemon-sh = pkgs.writeShellScriptBin "audio-balance-daemon" ''
    export PACTL=${pkgs.pulseaudio}/bin/pactl
    export PW_DUMP=${pkgs.pipewire}/bin/pw-dump
    export PAREC=${pkgs.pulseaudio}/bin/parec
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
  #   out|<gain%>|<offset%>|<sink-input#>,...|<gain dB>|<slot>   in|<gain%>|<mic node.name>
  balance-gains-sh = pkgs.writeShellScriptBin "audio-balance-gains" ''
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/qs-audio/balance.json"
    [ -f "$state" ] || exit 0
    ${pkgs.jq}/bin/jq -r '
      (if .range then "range|\(.range.lo)|\(.range.hi)" else empty end),
      (.output[]? | "out|\(.gain)|\(.offset // 100)|" + ((.ids // []) | map(tostring) | join(",")) + "|\(.gain_db // 0)|\(.slot // "")"),
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
    id="$1"; pct="$2"
    [ -z "$id" ] || [ -z "$pct" ] && exit 1
    # which sink INDEX is this stream on?
    sidx=$(pactl list sink-inputs | awk -v want="$id" '
      /^Sink Input #/ { cur=substr($3,2) }
      /^\tSink:/      { if (cur==want) { print $2; exit } }')
    [ -z "$sidx" ] && exit 0
    # index -> name; must be a balance slot
    slot=$(pactl list short sinks | awk -v i="$sidx" '$1==i {print $2}')
    case "$slot" in applvl.*) ;; *) exit 0 ;; esac
    # find the applvl.<n>.out bridge sink-input and set its volume
    outid=$(pactl list sink-inputs | awk -v n="$slot.out" '
      /^Sink Input #/ { cur=substr($3,2) }
      /node\.name = / { if (index($0, "\"" n "\"")) { print cur; exit } }')
    [ -n "$outid" ] && pactl set-sink-input-volume "$outid" "$pct%"
    echo done
  '';

  tools = [
    balance-daemon-sh
    balance-read-sh
    balance-gains-sh
    balance-mutate-sh
    balance-setvol-sh
    bt-audio-connect-sh
    recency-sh
    default-sink-kind-sh
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
  inherit
    audio-xrun-guard-sh
    auto-mic-daemon-sh
    mix-sync-daemon-sh
    cast-sync-daemon-sh
    balance-daemon-sh
    ;

  # Everything on PATH: audio-* tools + the audioctl dispatcher.
  audio-tools = pkgs.symlinkJoin {
    name = "audio-tools";
    paths = tools ++ [ audioctl ];
  };
}
