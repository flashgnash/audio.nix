# Device fixes for this machine's audio hardware, whichever stack runs
# (chainmail or the legacy one): imported by common.nix.
{
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
  services.pipewire.wireplumber.extraConfig."53-usb-capture-headroom" = {
    "monitor.alsa.rules" = [
      {
        matches = [ { "node.name" = "~alsa_input\\.usb-.*"; } ];
        actions.update-props = {
          "api.alsa.headroom" = 512;
          # NOTE: demoting USB capture from the driver role (priority.driver
          # 100) DID stop the load storms (mic becomes a follower), but it
          # fragmented the clock domains — the mic chain ran at a different
          # quantum than the sink/echo-reference, so the WebRTC AEC could no
          # longer time-align and FAILED on speakers (echo leaked + its
          # residual suppressor ate whole words). Reverted 2026-10-09. The
          # correct fix keeps the mic a follower of THE SAME driver as the
          # echo reference (one clock domain) — a follow-up.
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
  services.pipewire.wireplumber.extraConfig."52-bluez-input-no-restore" = {
    "monitor.bluez.rules" = [
      {
        matches = [ { "node.name" = "~bluez_input\\..*"; } ];
        actions.update-props = {
          "state.restore-props" = false;
        };
      }
    ];
  };
}
