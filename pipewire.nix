# PipeWire audio stack, parameterised on the pipewire-screenaudio flake so it
# works both from the subflake (which binds its own input) and from the parent
# config (which passes inputs.pipewire-screenaudio). Import as:
#   (import ./pipewire.nix pipewire-screenaudio-flake)
pipewire-screenaudio:
{ pkgs, ... }:

{

  security.rtkit.enable = true;

  # Allow latency-sensitive audio HELPERS (not just PipeWire's own rtkit-managed
  # threads) to obtain real-time scheduling, so a saturated CPU — a screen-cast
  # encoder, share, game — can't starve them into stutter. The tailnet route's
  # parec/gst capture is the motivating case: it must preempt the cast, not
  # queue behind it. The helper requests a modest FIFO priority BELOW PipeWire's
  # own; this only raises the ceiling (processes still run normally unless they
  # explicitly ask for RT).
  #   - loginLimits: interactive / graphical PAM sessions (terminal launches).
  #   - systemd DefaultLimitRTPRIO: the route is usually launched from the
  #     quickshell audio panel, i.e. under `systemd --user`, which does NOT get
  #     pam_limits — the user@ manager's own ceiling must be raised for its
  #     services (and their children) to go RT.
  # NB nice MUST be raised alongside rtprio: PipeWire's module-rt renices to
  # -11 BEFORE taking RT, and when that first setpriority() fails (hard nice
  # cap 0) it abandons the WHOLE RT setup — rtprio ceiling and all — leaving
  # every data-loop at plain SCHED_OTHER. Verified live 2026-10-06: rtprio
  # 95/95 present, data-loops still TS, "could not set nice-level to -11:
  # Permission denied" in the log; audio crackled whenever a nix build
  # saturated the CPU.
  security.pam.loginLimits = [
    {
      domain = "@audio";
      item = "rtprio";
      type = "-";
      value = "95";
    }
    {
      domain = "@audio";
      item = "nice";
      type = "-";
      value = "-19";
    }
  ];
  systemd.settings.Manager.DefaultLimitRTPRIO = 95;
  systemd.settings.Manager.DefaultLimitNICE = "-19";
  systemd.user.extraConfig = ''
    DefaultLimitRTPRIO=95
    DefaultLimitNICE=-19
  '';

  services.pulseaudio.enable = false;

  programs.noisetorch.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;

    # Never yank a Bluetooth headset into its low-quality HFP/HSP "headset" profile
    # just because some app opened a recording stream: that silently drops A2DP
    # music output to 16 kHz phone-call quality. The BT mic is therefore only ever
    # available when the profile is switched to headset MANUALLY. audio-bt-mic-release
    # (flakes/audio/tools-module.nix) returns the card to A2DP once the mic is idle.
    wireplumber.extraConfig."51-bluez-no-headset-autoswitch" = {
      "wireplumber.settings"."bluetooth.autoswitch-to-headset-profile" = false;
    };

    # Keep USB capture devices OUT of the graph-driver role. A full-speed USB
    # mic (PodMic) defaults to priority.driver 2100 — ABOVE every output sink
    # (~1108) — so the ENTIRE graph clocks off it. Full-speed USB has only
    # 1 ms of isochronous timing granularity, so under load (a build, a game,
    # a Hyprland-crash recovery spike) it misses cycle deadlines, and a DRIVER
    # xrun drops the whole graph's cycle → fractional-realtime "robot" audio
    # to every consumer. Headroom does NOT fix a driver storm (verified: 2048
    # samples, still storming); only forcing the whole graph to a huge quantum
    # did, at the cost of output latency. Demoting the mic below the sinks
    # makes a RUNNING sink drive instead; the mic becomes a follower that
    # absorbs its own clock jitter via adaptive resampling — verified storm-
    # free at quantum 256 under load average 22 (2026-10-09). The 512-sample
    # headroom stays as cheap follower-side insurance.
    wireplumber.extraConfig."53-usb-capture-headroom" = {
      "monitor.alsa.rules" = [
        {
          matches = [ { "node.name" = "~alsa_input\\.usb-.*"; } ];
          actions.update-props = {
            "api.alsa.headroom" = 512;
            # below the sinks (~1108) so an active sink wins the driver role;
            # the mic still drives as a last resort if no sink is running.
            "priority.driver" = 100;
          };
        }
      ];
    };

    # Bluetooth A2DP source streams (a phone playing INTO this machine): never
    # let stream-restore resurrect a stale saved volume across reconnects (a
    # remembered 200% boost = +18 dB of digital clipping on the s16 stream).
    # The LIVE volume stays writable — the phone's own volume buttons drive it
    # via AVRCP absolute-volume, so the stream's slider in the mixer tracks
    # the device; everything further down the chain stays ours.
    wireplumber.extraConfig."52-bluez-input-no-restore" = {
      "monitor.bluez.rules" = [
        {
          matches = [ { "node.name" = "~bluez_input\\..*"; } ];
          actions.update-props = {
            "state.restore-props" = false;
          };
        }
      ];
    };

    # Make the RNNoise LADSPA plugin discoverable via PipeWire's LADSPA_PATH.
    # The filter-chain below references it by basename (`librnnoise_ladspa`),
    # which PipeWire resolves through this path — absolute paths are NOT honored.
    extraLadspaPackages = [
      pkgs.rnnoise-plugin.ladspa
      pkgs.lsp-plugins # autogain_stereo + limiter_stereo for the app-balance sinks
    ];

    # Mic filter stack: echo cancellation (WebRTC AEC) → RNNoise denoiser.
    # Exposes ONE virtual source `rnnoise_source` that the whole audio stack
    # lives behind, fed either by one selected mic or by the `combined_mics`
    # blend of all physical mics (see combine-stream below), with the
    # echo-cancel stage in between. Denoising is bypassed IN-GRAPH (a dry/wet
    # mixer), NOT by swapping the default device — so the filter can be toggled on
    # and off while `rnnoise_source` stays the single default source apps use.
    # The AEC stage is bypassed AT RUNTIME by retargeting the inner chain
    # capture between aec_source (on) and the selected mic (off) — see
    # audio-aec-set in tools.nix. The audio-aec-auto daemon drives it from
    # the default output: speakers/HDMI → on, headphones/headsets → off.
    # On headphones there is no acoustic echo to cancel, but webrtc's
    # residual-echo suppressor still fires whenever the reference is active
    # and suppresses the near-end voice instead (observed 2026-10-03:
    # "cancelling my own voice" during music + Discord).
    #
    # Graph: input fans (via `copy`) to two paths into a 2-input `mixer`:
    #   In 1 = dry (raw),  In 2 = wet (rnnoise output)
    # The mixer's "Gain 1"/"Gain 2" controls are the bypass switch:
    #   filter ON  -> Gain 1 = 0, Gain 2 = 1   (default below)
    #   filter OFF -> Gain 1 = 1, Gain 2 = 0
    # Flipped at runtime by qs-rnnoise-toggle (see hm-modules/quickshell/audio.nix)
    # via `pw-cli set-param <rnnoise_source id> Props`, no device switching.
    extraConfig.pipewire."99-input-denoising" = {
      "context.modules" = [
        # Mic combiner. Mixes every physical mic (ALSA + bluetooth) into ONE
        # virtual source `combined_mics`. Blending is OPT-IN: the quickshell
        # input popup's MIX toggle (hm-modules/quickshell/audio.nix) retargets
        # the RNNoise capture at combined_mics; by default the chain still
        # follows the single selected mic. Mics hot-plug in and out
        # automatically via stream.rules; each mic appears as its own recording
        # stream in pavucontrol/qpwgraph, so per-mic blend levels can be
        # adjusted there. Everything is downmixed to mono because the RNNoise
        # suppressor is mono.
        #
        # The match regexes MUST only ever hit hardware inputs — matching
        # `rnnoise_source` (also an Audio/Source) would create a feedback loop.
        {
          name = "libpipewire-module-combine-stream";
          flags = [ "nofail" ];
          args = {
            "combine.mode" = "source";
            "node.name" = "combined_mics";
            "node.description" = "Combined Microphones";
            # NO latency compensation: it inserts per-stream delay buffers
            # sized from each device's REPORTED latency, and wireless dongles
            # (Arctis/Maono) report values unrelated to their real radio
            # latency — the bogus delays both smeared the voice across mics
            # (audible doubling) and starved streams during simultaneous input
            # (one mic dropping out). Mixing as-delivered keeps mics within a
            # few ms of each other, which reads as one voice.
            "combine.latency-compensate" = false;
            "combine.props" = {
              "audio.position" = [ "MONO" ];
              "audio.rate" = 48000;
            };
            # Fixed node.name so the mic-users enumerator can recognise these
            # server-side capture streams and not count them as mic users.
            # passive: the per-mic streams must never take part in a device's
            # processing cycle while the combiner itself is idle — a non-passive
            # combine stream can wedge the device driver (it waits on a stream
            # that never processes), which stalls the ENTIRE graph.
            # async: passive is not enough — the links alone still merge every
            # mic into ONE synchronous driver group behind a single clock, so a
            # device that wedges at the hardware level (Blue at cold boot:
            # stream starts, hw_ptr stays 0 forever) froze EVERY capture stream
            # on the machine, including mics it wasn't feeding. Async streams
            # keep each device in its own driver group at the cost of one
            # quantum of latency on the (opt-in) MIX path only.
            "stream.props" = {
              "node.name" = "capture.combined_mics";
              "node.passive" = true;
              "node.async" = true;
              # NEVER volume-restore these: every per-mic combiner stream
              # shares this node.name as its restore key, so a PipeWire
              # restart "restored" the automix daemon's GATED 2% onto the
              # live mic (speech arrived at -100 dB; whole words vanished,
              # 2026-10-06). The automix/mix UIs own these volumes at
              # runtime; a fresh stream must start at unity and wait.
              "state.restore-props" = false;
              # ...and NEVER target-restore them either: the same shared key
              # saved a garbage target during a crash cascade and then
              # re-applied it on every restart — all combiner streams linked
              # to rnnoise_source ITSELF (the output feeding the input, the
              # exact loop the match-rule comment above warns about), chain
              # starved+looped, survives reboots because the restore DB is
              # persistent state (2026-10-06). These streams' targets are
              # defined by stream.rules alone.
              "state.restore-target" = false;
            };
            "stream.rules" = [
              {
                matches = [
                  # Capture the audio-mix-sync daemon's time-aligned
                  # `delayed.<mic>` wrappers, NOT raw devices: a wireless
                  # mic's radio transit (~46 ms on the Arctis) made the raw
                  # mix comb/echo, and a bare ~alsa_input.* also swept in the
                  # snd_aloop loopback device (piping played audio straight
                  # into the mic mix). The daemon wraps exactly the real
                  # usb/pci/bluez mics and time-aligns them.
                  {
                    "media.class" = "Audio/Source";
                    "node.name" = "~delayed\\..*";
                  }
                ];
                actions = {
                  create-stream = { };
                };
              }
            ];
          };
        }
        # NOTE: the output duplicator (`combined_out`) is intentionally NOT
        # loaded statically here. A static combine-sink is broken both ways:
        # passive device streams never wake the hardware sinks (MIX on → apps
        # hang forever), and non-passive ones keep every sink running from
        # boot, which wedged the Arctis in a permanent XRUN (no audio at all).
        # The quickshell MIX toggle instead loads pipewire-pulse's
        # module-combine-sink on demand and unloads it when MIX goes off —
        # see outdup-toggle-sh in hm-modules/quickshell/audio.nix.
        # Acoustic echo cancellation (WebRTC AEC), ahead of RNNoise. It must
        # sit BEFORE the denoiser: the canceller correlates the mic signal
        # against what the speakers are playing, and RNNoise's gate/suppression
        # is non-linear — echo mangled by it can no longer be matched to the
        # reference, so AEC after RNNoise barely cancels anything.
        #
        # This stage's mic capture TAKES OVER the node name
        # `capture.rnnoise_source`: that literal name (and its :input_MONO
        # port) is the interface every selection tool keys on —
        # audio-rnnoise-set-input's target.object + link sweep,
        # audio-rnnoise-current-input, the auto-mic crossfade, the quickshell
        # MIX toggle — so by holding it the AEC stage inherits ALL
        # mic-selection plumbing unchanged. The RNNoise chain below is renamed
        # to `capture.rnnoise_source.filter` and pinned statically at the
        # cancelled output `aec_source` (both masked as internal plumbing by
        # internal_node() in flakes/audio/tools.nix + the python twin in
        # hm-modules/phone-mic/audio_devices.py).
        #
        # monitor.mode: no virtual sink is created — the echo reference is
        # tapped from the DEFAULT SINK's monitor, so playback routing stays
        # untouched (applvl/strmfx chains keep feeding the real sink, and the
        # reference follows wherever the default output goes).
        #
        # capture boot target = combined_mics: a bare stream would follow the
        # default source, which is rnnoise_source itself — a feedback loop
        # WirePlumber can NOT prevent here (its loop guard only sees within a
        # single node.link-group, and this loop would span two modules).
        # combined_mics only ever ingests the delayed.<mic> wrappers, so it is
        # loop-safe; the mic picker / auto-mic daemon retargets to the chosen
        # mic via metadata moments after session start, exactly as before.
        {
          name = "libpipewire-module-echo-cancel";
          # nofail: if the webrtc canceller is unavailable this must not take
          # down PipeWire — the RNNoise chain below then fails SAFE (see its
          # dont-reconnect comment) rather than looping.
          flags = [ "nofail" ];
          args = {
            "monitor.mode" = true;
            # Echo cancellation ONLY. webrtc's bundled extras stay off: the
            # mic-path policy is "rnnoise + routing, no AGC/EQ", and webrtc's
            # own noise suppression would double up on RNNoise downstream.
            "aec.args" = {
              "webrtc.gain_control" = false;
              "webrtc.noise_suppression" = false;
              "webrtc.high_pass_filter" = false;
              # Sink-monitor echo reference carries an unknown (output+room)
              # delay; these let webrtc converge on it instead of falling back
              # to aggressive residual suppression.
              "webrtc.delay_agnostic" = true;
              "webrtc.extended_filter" = true;
            };
            "capture.props" = {
              "node.name" = "capture.rnnoise_source";
              "node.description" = "Echo Cancel Capture";
              "node.passive" = true;
              "audio.rate" = 48000;
              "audio.position" = [ "MONO" ];
              "target.object" = "combined_mics";
            };
            "source.props" = {
              "node.name" = "aec_source";
              "node.description" = "Echo Cancelled Mic";
              "audio.rate" = 48000;
              "audio.position" = [ "MONO" ];
            };
            # In monitor.mode the reference tap takes SINK.props (confirmed
            # live: with these unset it appeared under the module default name
            # `echo-cancel-sink`); playback.props is unused in this mode.
            "sink.props" = {
              "node.name" = "aec_ref";
              "node.description" = "Echo Cancel Reference";
              "node.passive" = true;
              "audio.rate" = 48000;
            };
          };
        }
        {
          name = "libpipewire-module-filter-chain";
          # nofail: a plugin load failure must never take down all of PipeWire.
          flags = [ "nofail" ];
          args = {
            "node.description" = "Noise Canceling Source";
            "media.name" = "Noise Canceling Source";
            "filter.graph" = {
              nodes = [
                {
                  type = "builtin";
                  label = "copy";
                  name = "split";
                }
                {
                  type = "ladspa";
                  name = "rnnoise";
                  plugin = "librnnoise_ladspa";
                  label = "noise_suppressor_mono";
                  control = {
                    # Threshold stays high so near-silent input is gated and
                    # RNNoise can't hallucinate buzzing / half-voices when you're
                    # quiet. To avoid clipping speech, the GRACE keeps the gate open
                    # once real speech has opened it: it holds through soft
                    # mid-sentence parts and trailing ends, and only sustained
                    # silence past it re-gates. Retroactive grace passes the moment
                    # before onset so word starts aren't clipped.
                    # 2026-08-16: grace 700/40 → 1200/100 for soft trailing words.
                    # Threshold stays 90: an 85 experiment promptly brought the
                    # hallucination back once the Blue's capture volume was
                    # restored to 100%. NB the REAL cause of "words cut off" was
                    # that capture volume silently sitting at 42% (-22.6 dB) —
                    # starving the VAD of level. If clipping returns, check
                    # `pactl get-source-volume` on the mic before touching these.
    # 90 → 95 (2026-08-16): at 90 the fan's voiced-ish buzz kept
                    # the gate open through long silences (measured: output
                    # floor -44 dBFS continuous while quiet) and the AGC lifted
                    # it. Speech at proper gain clears 95 comfortably.
                    # 95 → 88 (2026-10-06): 95 chopped soft mid-word syllables
                    # on the (quieter, dynamic) RØDE PodMic ("I am spe—clearly").
                    # The level gate downstream now owns fan rejection — any
                    # fan residue the looser VAD passes dies at -45 dBFS — so
                    # the VAD can afford to favour speech continuity again.
                    "VAD Threshold (%)" = 88.0;
                    "VAD Grace Period (ms)" = 1200;
                    "Retroactive VAD Grace (ms)" = 100;
                  };
                }
                # Distance-compensating leveler (requested 2026-10-06: leaned
                # back, the pod is still the better mic but "way quieter").
                # In-graph, AFTER RNNoise (it levels VOICE, not fan noise),
                # BEFORE the gate (the gate's auto-fitted threshold must keep
                # judging a NORMALIZED signal — leveling after it would make
                # the calibration domain drift with posture). NEVER capture
                # volumes — that's the Aug-2026 revert; this stage is
                # invisible to every volume control the user owns.
                # Slow loop only (quick amplifier off, short gains 0): posture
                # changes are seconds-scale, and a fast AGC pumps. Silence
                # level -50 LUFS freezes the gain whenever only RNNoise
                # residue (-55 dB and below) is present, so gain never winds
                # up during pauses; the gate downstream still guarantees
                # digital silence to consumers.
                {
                  type = "ladspa";
                  name = "agc";
                  plugin = "lsp-plugins-ladspa";
                  label = "http://lsp-plug.in/plugins/ladspa/autogain_mono";
                  control = {
                    "Desired loudness level (LUFS)" = -24.0;
                    # -45 freeze floor + 8 dB gain cap: at -50/+18 the
                    # amplified post-RNNoise residue cleared the downstream
                    # gate, pulsing fan/keyboard noise into a quiet mic.
                    "The level of silence (LUFS)" = -45.0;
                    "Level drift (dB)" = 6.0;
                    "Enable maximum amplification gain limitation" = 1.0;
                    "The maximum amplification gain (dB)" = 8.0;
                    "Loudness measuring long period (ms)" = 2000.0;
                    "Long gain grow amount" = 3.0;
                    "Long gain fall amount" = 3.0;
                    "Short gain grow amount" = 0.0;
                    "Short gain fall amount" = 0.0;
                    "Enable quick amplifier" = 0.0;
                    "Weighting function" = 5.0;
                  };
                }
                # Safety limiter: a leveler that may add up to +18 dB needs a
                # hard ceiling so a sudden close shout can't clip (-1 dBFS,
                # same idiom as the applvl output chains).
                {
                  type = "ladspa";
                  name = "lim";
                  plugin = "lsp-plugins-ladspa";
                  label = "http://lsp-plug.in/plugins/ladspa/limiter_mono";
                  control = {
                    # -1 dBFS ceiling: 10^(-1/20)
                    "Threshold (G)" = 0.891;
                    "Lookahead (ms)" = 5.0;
                  };
                }
                # Level gate AFTER RNNoise: the VAD gate alone chains open on
                # loud fans (each false VAD hit buys another grace period —
                # measured 15+ s of -55..-75 dBFS mangled-fan residue after
                # speech, audible via any downstream AGC/monitor, 2026-10-06).
                # Real speech leaves RNNoise 20+ dB above this threshold, the
                # fan residue sits 10-30 dB below it, so the gate is
                # deterministic: zero attack (word onsets never clip — the
                # VAD's retroactive grace already feeds the start through),
                # 300 ms release + hold bridges inter-word dips, and the
                # -72 dB floor means sustained silence is DIGITALLY silent to
                # every consumer. Wet path only — the dry bypass stays raw.
                {
                  type = "ladspa";
                  name = "gate";
                  plugin = "lsp-plugins-ladspa";
                  label = "http://lsp-plug.in/plugins/ladspa/gate_mono";
                  control = {
                    # Cold-boot SEED only — the automix daemon's gate autofit
                    # re-derives the threshold from the user's measured speech
                    # level within seconds of talking (speech − 25 dB; it
                    # landed at −58.6 here). The seed errs GENTLE (-55 dB): a
                    # too-hot seed chopped soft syllables for the first ~20 s
                    # after every PipeWire restart until autofit converged
                    # (2026-10-06); a too-soft one merely risks faint fan
                    # residue for the same window.  -55 dBFS = 10^(-55/20)
                    "Curve threshold (G)" = 0.00178;
                    "Attack (ms)" = 0.0;
                    "Release (ms)" = 300.0;
                    "Hold time (ms)" = 200.0;
                    # fully closed = -72 dB (port minimum)
                    "Reduction (G)" = 0.00025119;
                  };
                }
                {
                  type = "builtin";
                  label = "mixer";
                  name = "mix";
                  # Default: dry off, wet on => filtering ON at boot.
                  control = {
                    "Gain 1" = 0.0;
                    "Gain 2" = 1.0;
                  };
                }
              ];
              links = [
                {
                  output = "split:Out";
                  input = "rnnoise:Input";
                }
                {
                  output = "split:Out";
                  input = "mix:In 1";
                }
                {
                  output = "rnnoise:Output";
                  input = "agc:Input";
                }
                {
                  output = "agc:Output";
                  input = "lim:Input";
                }
                {
                  output = "lim:Output";
                  input = "gate:Input";
                }
                {
                  output = "gate:Output";
                  input = "mix:In 2";
                }
              ];
              inputs = [ "split:In" ];
              outputs = [ "mix:Out" ];
            };
            "capture.props" = {
              # Renamed from capture.rnnoise_source — the AEC capture above now
              # holds that interface name. Still prefix-matched by the
              # internal_node() mask, while the set-input link sweep's
              # `^capture\.rnnoise_source:input` regex only matches the AEC
              # node (the `:` anchors it).
              "node.name" = "capture.rnnoise_source.filter";
              "node.passive" = true;
              "audio.rate" = 48000;
              # Boots at the cancelled output; audio-aec-set retargets it
              # between aec_source (AEC on) and the selected mic (AEC off).
              # NO node.dont-reconnect here: it silently blocks metadata
              # retargets (verified live 2026-10-03 — the move never happened,
              # and a stray second link appeared instead: doubled voice
              # mid-call). Loop safety doesn't need it anyway: this capture
              # shares the filter-chain's node.link-group with rnnoise_source,
              # so WirePlumber's loop guard refuses the self-link fallback if
              # aec_source disappears.
              "target.object" = "aec_source";
            };
            "playback.props" = {
              "node.name" = "rnnoise_source";
              "media.class" = "Audio/Source";
              "audio.rate" = 48000;
            };
          };
        }
      ];
    };

    # ── Per-app OUTPUT balancing: a fixed pool of leveler+limiter sinks ──────
    # A STATIC pool of filter-chain sinks `applvl.0..applvl.N-1`. The
    # audio-balance daemon (flakes/audio/balance_daemon.py) parks a running app
    # on a free slot by MOVING its sink-inputs here (reversible, never creates
    # graph nodes — so it can't wedge the graph); the chain LUFS-levels that app
    # to a common target and brick-wall limits transients before handing off to
    # the real default sink. Everything stays 32-bit float end to end and the
    # limiter caps the peak, so the one float->int conversion at the DAC can't
    # clip — transparent.
    #
    # node.always-process (2026-09-09): slots used to suspend when idle, but a
    # NEW stream then landed on a suspended chain that had to wake + activate
    # its LSP plugins mid-stream-start — a loud CRACK of static every time
    # someone started talking in a call. Keeping the chains always processing
    # trades a little constant CPU (silence through leveler+limiter) for
    # pop-free stream starts; it also keeps the downstream sink awake, which
    # kills the DAC's own resume pop from silence.
    #
    # These are internal plumbing: the audio-devices LocalModule masks `applvl.*`
    # so they never appear as user-selectable outputs.
    #
    # Tuning (adjust via rb + listen):
    #   target -18 LUFS, silence floor -60 (freeze gain in near-silence, no pump),
    #   max amp +12 dB (don't lift a quiet app's noise floor), 3 s long period
    #   (slow, smooth), long grow/fall 4 (symmetric, ~12.6 dB/s) so leveling
    #   drifts rather than flinches; BOTH short paths disabled (2026-08-28: the
    #   short fall at 6 dB per ~9 ms gutted transients mid-bang — "loud sounds
    #   get neutered" — and the limiter below already catches true spikes);
    #   limiter ceiling -1 dBFS (0.891).
    extraConfig.pipewire."99-app-balance" = {
      "context.modules" = builtins.genList (i: {
        name = "libpipewire-module-filter-chain";
        # nofail: a plugin load failure must never take down PipeWire.
        flags = [ "nofail" ];
        args = {
          "node.description" = "App Balance ${toString i}";
          "media.name" = "App Balance ${toString i}";
          "filter.graph" = {
            nodes = [
              {
                type = "ladspa";
                name = "lvl";
                plugin = "lsp-plugins-ladspa";
                label = "http://lsp-plug.in/plugins/ladspa/autogain_stereo";
                control = {
                  "Desired loudness level (LUFS)" = -18.0;
                  "The level of silence (LUFS)" = -60.0;
                  "Level drift (dB)" = 6.0;
                  "Enable maximum amplification gain limitation" = 1.0;
                  "The maximum amplification gain (dB)" = 12.0;
                  "Loudness measuring long period (ms)" = 3000.0;
                  "Long gain grow amount" = 4.0;
                  "Long gain fall amount" = 4.0;
                  "Short gain grow amount" = 0.0;
                  "Short gain fall amount" = 0.0;
                  "Weighting function" = 5.0;
                };
              }
              {
                type = "ladspa";
                name = "lim";
                plugin = "lsp-plugins-ladspa";
                label = "http://lsp-plug.in/plugins/ladspa/limiter_stereo";
                control = {
                  # -1 dBFS ceiling: 10^(-1/20) ≈ 0.891 (linear).
                  "Threshold (G)" = 0.891;
                  "Attack time (ms)" = 1.0;
                  "Release time (ms)" = 8.0;
                };
              }
              # Voice-chat duck gain (audio-duck): its own layer AFTER the
              # leveler+limiter, driven live by the balance daemon via
              # `pw-cli set-param <sink> Props '{params=["duck_l:Gain 1" …]}'`
              # (same in-graph mechanism as the rnnoise dry/wet bypass). The
              # user's bridge volume is NEVER touched by ducking — their mix
              # stays theirs, this is a separate multiply. Unity at boot.
              {
                type = "builtin";
                label = "mixer";
                name = "duck_l";
                control."Gain 1" = 1.0;
              }
              {
                type = "builtin";
                label = "mixer";
                name = "duck_r";
                control."Gain 1" = 1.0;
              }
            ];
            links = [
              {
                output = "lvl:Output L";
                input = "lim:Input L";
              }
              {
                output = "lvl:Output R";
                input = "lim:Input R";
              }
              {
                output = "lim:Output L";
                input = "duck_l:In 1";
              }
              {
                output = "lim:Output R";
                input = "duck_r:In 1";
              }
            ];
            inputs = [
              "lvl:Input L"
              "lvl:Input R"
            ];
            outputs = [
              "duck_l:Out"
              "duck_r:Out"
            ];
          };
          "capture.props" = {
            "node.name" = "applvl.${toString i}";
            "node.description" = "App Balance ${toString i}";
            "media.class" = "Audio/Sink";
            "audio.rate" = 48000;
            "audio.position" = [
              "FL"
              "FR"
            ];
            # never suspend: waking a suspended chain on stream arrival popped
            # loudly (see the header comment).
            "node.always-process" = true;
          };
          "playback.props" = {
            "node.name" = "applvl.${toString i}.out";
            "audio.rate" = 48000;
            "audio.position" = [
              "FL"
              "FR"
            ];
            # NOT passive: match the canonical "sink with filter" pattern so the
            # slot reliably drives the real sink when an app is parked on it.
            "node.always-process" = true;
          };
        };
      }) 4;
    };

    # ── Per-stream FX presets: pinnable filter sinks ─────────────────────────
    # STATIC filter-chain sinks `strmfx.<preset>` a specific app's output can be
    # pinned to (e.g. put a Discord call on "voice"). Same pattern as the
    # applvl pool: the balance daemon MOVES the app's sink-inputs here (per the
    # rules in ~/.config/audio-streamfx/rules.json, set via audio-streamfx) —
    # it never creates graph nodes, idle sinks suspend (≈free), and the
    # `strmfx.<preset>.out` playback bridge carries the user's post-filter
    # volume trim. Masked as internal plumbing everywhere (internal_node()).
    #
    # Presets:
    #   voice — speech clarity for calls: high-pass the sub-voice rumble, lift
    #           presence, then the proven leveler+limiter pair from the applvl
    #           pool so quiet talkers come up and nobody clips.
    #   bass  — low-shelf boost for music, limiter to catch the added peaks.
    extraConfig.pipewire."99-stream-fx" =
      let
        limiter = {
          type = "ladspa";
          name = "lim";
          plugin = "lsp-plugins-ladspa";
          label = "http://lsp-plug.in/plugins/ladspa/limiter_stereo";
          control = {
            # -1 dBFS ceiling: 10^(-1/20) ≈ 0.891 (linear).
            "Threshold (G)" = 0.891;
            "Attack time (ms)" = 1.0;
            "Release time (ms)" = 8.0;
          };
        };
        # Builtin biquads are mono — one node per channel, suffixed _l/_r.
        biquadPair = name: label: control: side: {
          type = "builtin";
          inherit label control;
          name = "${name}_${side}";
        };
        # Append the voice-chat duck gain stage (audio-duck) to a preset graph:
        # two builtin mixers after the preset's final node, unity at boot, set
        # live by the balance daemon via pw-cli set-param — a separate multiply
        # so ducking never touches the user's bridge volume (their mix). Same
        # stage exists in every applvl chain above.
        withDuck = graph: graph // {
          nodes = graph.nodes ++ [
            {
              type = "builtin";
              label = "mixer";
              name = "duck_l";
              control."Gain 1" = 1.0;
            }
            {
              type = "builtin";
              label = "mixer";
              name = "duck_r";
              control."Gain 1" = 1.0;
            }
          ];
          links = graph.links ++ [
            {
              output = builtins.elemAt graph.outputs 0;
              input = "duck_l:In 1";
            }
            {
              output = builtins.elemAt graph.outputs 1;
              input = "duck_r:In 1";
            }
          ];
          outputs = [
            "duck_l:Out"
            "duck_r:Out"
          ];
        };
        mkFx = preset: desc: graph: {
          name = "libpipewire-module-filter-chain";
          # nofail: a plugin load failure must never take down PipeWire.
          flags = [ "nofail" ];
          args = {
            "node.description" = desc;
            "media.name" = desc;
            "filter.graph" = withDuck graph;
            "capture.props" = {
              "node.name" = "strmfx.${preset}";
              "node.description" = desc;
              "media.class" = "Audio/Sink";
              "audio.rate" = 48000;
              "audio.position" = [
                "FL"
                "FR"
              ];
              # never suspend — same wake-pop reasoning as the applvl pool.
              "node.always-process" = true;
            };
            "playback.props" = {
              "node.name" = "strmfx.${preset}.out";
              "audio.rate" = 48000;
              "audio.position" = [
                "FL"
                "FR"
              ];
              "node.always-process" = true;
            };
          };
        };
      in
      {
        "context.modules" = [
          (mkFx "voice" "Stream FX: Voice Clarity" {
            # Tuning history: 110 Hz HPF + a -2.5 dB dip @ 250 Hz "stripped the
            # bass from voices" (2026-09-09) — male fundamentals live at
            # 85–180 Hz and the warmth band right above, so both stages ate the
            # body of the voice. Now: HPF at 80 Hz (below fundamentals, still
            # kills rumble/handling noise), no mud dip, gentler +3 dB presence.
            nodes =
              (map
                (
                  side:
                  # rumble/handling noise below speech fundamentals
                  biquadPair "hp" "bq_highpass" {
                    "Freq" = 80.0;
                    "Q" = 0.707;
                  } side
                )
                [
                  "l"
                  "r"
                ]
              )
              ++ (map
                (
                  side:
                  # presence lift — consonant intelligibility
                  biquadPair "pres" "bq_peaking" {
                    "Freq" = 2800.0;
                    "Q" = 0.9;
                    "Gain" = 3.0;
                  } side
                )
                [
                  "l"
                  "r"
                ]
              )
              ++ [
                {
                  # Same proven leveler as the applvl pool: quiet talkers rise
                  # to the target, loud ones settle back — the "compressor" of
                  # this chain, with the limiter as the safety.
                  type = "ladspa";
                  name = "lvl";
                  plugin = "lsp-plugins-ladspa";
                  label = "http://lsp-plug.in/plugins/ladspa/autogain_stereo";
                  control = {
                    "Desired loudness level (LUFS)" = -18.0;
                    "The level of silence (LUFS)" = -60.0;
                    "Level drift (dB)" = 6.0;
                    "Enable maximum amplification gain limitation" = 1.0;
                    "The maximum amplification gain (dB)" = 12.0;
                    "Loudness measuring long period (ms)" = 3000.0;
                    "Long gain grow amount" = 4.0;
                    "Long gain fall amount" = 4.0;
                    "Short gain grow amount" = 0.0;
                    "Short gain fall amount" = 0.0;
                    "Weighting function" = 5.0;
                  };
                }
                limiter
              ];
            links = [
              {
                output = "hp_l:Out";
                input = "pres_l:In";
              }
              {
                output = "hp_r:Out";
                input = "pres_r:In";
              }
              {
                output = "pres_l:Out";
                input = "lvl:Input L";
              }
              {
                output = "pres_r:Out";
                input = "lvl:Input R";
              }
              {
                output = "lvl:Output L";
                input = "lim:Input L";
              }
              {
                output = "lvl:Output R";
                input = "lim:Input R";
              }
            ];
            inputs = [
              "hp_l:In"
              "hp_r:In"
            ];
            outputs = [
              "lim:Output L"
              "lim:Output R"
            ];
          })
          (mkFx "bass" "Stream FX: Bass Boost" {
            nodes =
              (map
                (
                  side:
                  biquadPair "bs" "bq_lowshelf" {
                    "Freq" = 100.0;
                    "Q" = 0.707;
                    "Gain" = 6.0;
                  } side
                )
                [
                  "l"
                  "r"
                ]
              )
              ++ [ limiter ];
            links = [
              {
                output = "bs_l:Out";
                input = "lim:Input L";
              }
              {
                output = "bs_r:Out";
                input = "lim:Input R";
              }
            ];
            inputs = [
              "bs_l:In"
              "bs_r:In"
            ];
            outputs = [
              "lim:Output L"
              "lim:Output R"
            ];
          })
        ];
      };
  };

  environment.systemPackages = with pkgs; [
    playerctl
    pulseaudio

    (firefox.override {
      nativeMessagingHosts = [
        pipewire-screenaudio.packages.${pkgs.stdenv.hostPlatform.system}.default
      ];
    })
  ];

}
