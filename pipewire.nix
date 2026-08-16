# PipeWire audio stack, parameterised on the pipewire-screenaudio flake so it
# works both from the subflake (which binds its own input) and from the parent
# config (which passes inputs.pipewire-screenaudio). Import as:
#   (import ./pipewire.nix pipewire-screenaudio-flake)
pipewire-screenaudio:
{ pkgs, ... }:

{

  security.rtkit.enable = true;

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
    extraLadspaPackages = [ pkgs.rnnoise-plugin.ladspa ];

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
                  { "media.class" = "Audio/Source"; "node.name" = "~alsa_input.*"; }
                  { "media.class" = "Audio/Source"; "node.name" = "~bluez_input.*"; }
                ];
                actions = { create-stream = { }; };
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
                    # 2026-08-16: 90/700/40 → 85/1200/100 — the Arctis headset mic
                    # (mono, lower SNR than the Blue up close) clipped word endings:
                    # soft tails never reached 90% confidence, so the gate closed
                    # mid-word once the grace ran out. If buzzing/half-voices return
                    # when idle, raise the threshold back toward 90 before touching
                    # the grace.
                    "VAD Threshold (%)" = 85.0;
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
              ];
              links = [
                { output = "split:Out"; input = "rnnoise:Input"; }
                { output = "split:Out"; input = "mix:In 1"; }
                { output = "rnnoise:Output"; input = "mix:In 2"; }
              ];
              inputs = [ "split:In" ];
              outputs = [ "mix:Out" ];
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
