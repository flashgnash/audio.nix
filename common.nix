# What every PipeWire host needs whichever audio stack runs (chainmail,
# services.chainmail; or the legacy one, ./pipewire.nix): real-time limits
# for audio helpers, this machine's device fixes, pactl/playerctl and
# Firefox's screen-audio host. In module-sets' universal-modules.
# Parameterised on the pipewire-screenaudio flake like ./pipewire.nix used
# to be. Import as:
#   (import ./common.nix pipewire-screenaudio-flake)
pipewire-screenaudio:
{ pkgs, ... }:
{
  imports = [ ./device-rules.nix ];

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
