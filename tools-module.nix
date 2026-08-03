# Installs the audio-* backend tools (+ audioctl dispatcher) system-wide and
# runs the two daemons as user services. UIs (quickshell or anything else)
# drive the stack purely through these commands and their statefiles, and can
# gate their controls on `programs.audioctl.enable` (via osConfig from
# home-manager).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  tools = import ./tools.nix { inherit pkgs; };
  cfg = config.programs.audioctl;
in
{
  options.programs.audioctl.enable = lib.mkEnableOption "audio backend tools (audioctl + daemons)" // {
    default = true;
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ tools.audio-tools ];

    # Passive USB-audio crackle guard: raises the USB sinks' ALSA headroom
    # when they actually underrun and decays it when quiet. Opt-in via the
    # flag file (audio-xrun-guard-toggle manages it); ConditionPathExists
    # makes the choice persist across logins.
    systemd.user.services.audio-xrun-guard = {
      description = "USB audio xrun guard (auto headroom)";
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      unitConfig.ConditionPathExists = "%E/qs-audio-xrun-guard-enabled";
      serviceConfig = {
        ExecStart = "${tools.audio-xrun-guard-sh}/bin/audio-xrun-guard";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

    # Auto-switch microphone daemon. Idle (spawns nothing) until the config
    # at ~/.config/auto-mic/config.json enables it with >=2 candidate mics.
    systemd.user.services.auto-mic = {
      description = "Automatic microphone switcher (VAD-driven)";
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${tools.auto-mic-daemon-sh}/bin/audio-auto-mic-daemon";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
