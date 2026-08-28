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
  security.pam.loginLimits = [
    {
      domain = "@audio";
      item = "rtprio";
      type = "-";
      value = "95";
    }
  ];
  systemd.settings.Manager.DefaultLimitRTPRIO = 95;
  systemd.user.extraConfig = "DefaultLimitRTPRIO=95";

  services.pulseaudio.enable = false;

  programs.noisetorch.enable = true;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;

    # Make the RNNoise LADSPA plugin discoverable via PipeWire's LADSPA_PATH.
    # The filter-chain below references it by basename (`librnnoise_ladspa`),
    # which PipeWire resolves through this path — absolute paths are NOT honored.
    extraLadspaPackages = [
      pkgs.rnnoise-plugin.ladspa
      pkgs.ladspaPlugins # swh collection — sc4m compressor for the AGC stage
      pkgs.lsp-plugins # autogain_mono (LUFS leveler) + limiter_mono (output cap)
    ];

    # RNNoise mic denoiser. Exposes ONE virtual source `rnnoise_source` that the
    # whole audio stack lives behind, fed either by one selected mic or by the
    # `combined_mics` blend of all physical mics (see combine-stream below). Denoising is bypassed IN-GRAPH (a dry/wet
    # mixer), NOT by swapping the default device — so the filter can be toggled on
    # and off while `rnnoise_source` stays the single default source apps use.
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
                  # High-pass before everything: PC-fan rumble/hum sits below
                  # ~150 Hz where RNNoise is weakest, and a spin-up's shifting
                  # pitch defeats its steady-noise tracking (audible buzz).
                  # 100 Hz shaves the fan band while leaving voice fundamentals
                  # (~85 Hz+) essentially intact.
                  type = "builtin";
                  label = "bq_highpass";
                  name = "hpf";
                  control = {
                    # 100 → 140 (2026-08-16): spin-ups still audible at 100.
                    "Freq" = 140.0;
                  };
                }
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
                    "VAD Threshold (%)" = 95.0;
                    "VAD Grace Period (ms)" = 1200;
                    "Retroactive VAD Grace (ms)" = 100;
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
                {
                  # AGC: a slow leveling compressor (SC4 mono, swh) evens out
                  # near/far mic distance. Post-mix so it applies with the
                  # denoiser on OR bypassed; post-rnnoise so its makeup gain
                  # boosts cleaned speech, not the noise floor. Close speech
                  # (~-10 dBFS) and far speech (~-30 dBFS) land within ~3 dB
                  # of each other instead of 20.
                  type = "ladspa";
                  name = "agc";
                  plugin = "sc4m_1916";
                  label = "sc4m";
                  control = {
                    "RMS/peak" = 0.0; # RMS sensing — smooth, no pumping
                    "Attack time (ms)" = 15.0;
                    "Release time (ms)" = 500.0;
                    # -30/+12 → -26/+8 (2026-08-16): full boost on very soft
                    # speech lifted the residual fan under it into audibility.
                    "Threshold level (dB)" = -26.0;
                    "Ratio (1:n)" = 8.0;
                    "Knee radius (dB)" = 10.0;
                    "Makeup gain (dB)" = 8.0;
                  };
                }
                {
                  # Loudness leveler (LSP Autogain, LUFS-based). sc4m above evens
                  # FAST near/far dynamics; this hits a SLOW integrated-loudness
                  # target so the mic sits at the same perceived level as every
                  # other source, without pumping. Because it normalises BEFORE
                  # the source volume fader, the panel mic slider now reads as
                  # "100% = matched target loudness, 150% = boosted above it".
                  #
                  # Starting tune — adjust via `rb` + listen (like the sc4m notes):
                  #   Desired loudness  -20 LUFS  = the target everything converges to
                  #   Silence floor     -50 LUFS  = below this it FREEZES the gain, so
                  #                                 room/fan noise in your pauses is
                  #                                 never amplified up (the anti-pump)
                  #   Max amp +20 dB              = ceiling on boost (won't chase silence)
                  #   Long grow/fall 6 dB, 700 ms = slow, smooth leveling (no jumping)
                  #   Short grow 0 / fall 4       = allow a quick DUCK on a shout, but
                  #                                 never a quick boost
                  type = "ladspa";
                  name = "lvl";
                  plugin = "lsp-plugins-ladspa";
                  label = "http://lsp-plug.in/plugins/ladspa/autogain_mono";
                  control = {
                    "Desired loudness level (LUFS)" = -20.0;
                    "The level of silence (LUFS)" = -50.0;
                    "Level drift (dB)" = 6.0;
                    "Enable maximum amplification gain limitation" = 1.0;
                    "The maximum amplification gain (dB)" = 20.0;
                    "Loudness measuring long period (ms)" = 700.0;
                    "Long gain grow amount" = 6.0;
                    "Long gain fall amount" = 6.0;
                    "Short gain grow amount" = 0.0;
                    "Short gain fall amount" = 4.0;
                    "Weighting function" = 5.0;
                  };
                }
              ];
              links = [
                {
                  output = "hpf:Out";
                  input = "split:In";
                }
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
                  input = "mix:In 2";
                }
                {
                  output = "mix:Out";
                  input = "agc:Input";
                }
                {
                  output = "agc:Output";
                  input = "lvl:Input";
                }
              ];
              inputs = [ "hpf:In" ];
              outputs = [ "lvl:Output" ];
            };
            "capture.props" = {
              "node.name" = "capture.rnnoise_source";
              "node.passive" = true;
              "audio.rate" = 48000;
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
    # the real default sink. Idle slots have no client and PipeWire suspends them
    # (≈free). Everything stays 32-bit float end to end and the limiter caps the
    # peak, so the one float->int conversion at the DAC can't clip — transparent.
    #
    # These are internal plumbing: the audio-devices LocalModule masks `applvl.*`
    # so they never appear as user-selectable outputs.
    #
    # Tuning (adjust via rb + listen, like the mic sc4m/autogain notes):
    #   target -18 LUFS, silence floor -60 (freeze gain in near-silence, no pump),
    #   max amp +12 dB (don't lift a quiet app's noise floor), 1 s long period
    #   (slow, smooth), fall (6) faster than grow (4) so a spike ducks quickly but
    #   a return to normal eases back up; limiter ceiling -1 dBFS (0.891).
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
                  "Loudness measuring long period (ms)" = 1000.0;
                  "Long gain grow amount" = 4.0;
                  "Long gain fall amount" = 6.0;
                  "Short gain grow amount" = 0.0;
                  "Short gain fall amount" = 6.0;
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
            ];
            inputs = [
              "lvl:Input L"
              "lvl:Input R"
            ];
            outputs = [
              "lim:Output L"
              "lim:Output R"
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
          };
          "playback.props" = {
            "node.name" = "applvl.${toString i}.out";
            "audio.rate" = 48000;
            "audio.position" = [
              "FL"
              "FR"
            ];
            # NOT passive: match the canonical "sink with filter" pattern so the
            # slot reliably drives the real sink when an app is parked on it. An
            # idle slot has no client feeding it, so PipeWire auto-suspends it
            # anyway (≈free) — passive here risked the driver-starvation the
            # static combine-sinks hit.
          };
        };
      }) 4;
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
