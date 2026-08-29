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
  options.programs.audioctl.enable =
    lib.mkEnableOption "audio backend tools (audioctl + daemons)"
    // {
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

    # Mic mix-sync daemon: keeps a fixed-delay `delayed.<mic>` wrapper per
    # physical mic and auto-measures the delays (speech cross-correlation) so
    # MIX mode mixes in-phase. combined_mics captures these wrappers — with
    # this service down, MIX mode has no inputs (single-mic mode unaffected).
    systemd.user.services.audio-mix-sync = {
      description = "Microphone mix time-alignment (auto-measured delays)";
      after = [
        "graphical-session.target"
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${tools.mix-sync-daemon-sh}/bin/audio-mix-sync-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };

    # Cast audio time-sync daemon: while a Chromecast is a member of the output
    # MIX set, auto-measures its buffer latency and delays the local outputs to
    # match (via `delayed.<sink>` wrappers). Started on demand by the SYNC toggle;
    # ConditionPathExists makes the choice persist across logins, and the daemon
    # self-idles unless a cast is actually a mix member.
    systemd.user.services.audio-cast-sync = {
      description = "Chromecast audio time-alignment (auto-measured delay)";
      after = [
        "graphical-session.target"
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      unitConfig = {
        # ON by default: run unless the `disabled` marker exists. The daemon
        # self-idles when no cast is a mix member, so always-eligible is cheap.
        ConditionPathExists = "!%S/audio-cast-sync/disabled";
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStart = "${tools.cast-sync-daemon-sh}/bin/audio-cast-sync-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };

    # Per-app output balancing daemon. Idle (assigns nothing) until the config
    # at ~/.config/audio-balance/config.json enables it. It only MOVES app
    # sink-inputs onto the static applvl.* filter-chain pool (declared in
    # pipewire.nix) — never creates graph nodes — so it can't wedge the graph.
    systemd.user.services.audio-balance = {
      description = "Per-app output loudness balancing (leveler + limiter)";
      after = [
        "graphical-session.target"
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      # If pipewire-pulse isn't up yet `pactl subscribe` fails and the daemon
      # exits; restart unconditionally rather than trip the start limit.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${tools.balance-daemon-sh}/bin/audio-balance-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };

    # Auto-switch microphone daemon. Idle (spawns nothing) until the config
    # at ~/.config/auto-mic/config.json enables it with >=2 candidate mics.
    systemd.user.services.auto-mic = {
      description = "Automatic microphone switcher (VAD-driven)";
      after = [
        "graphical-session.target"
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      # If pipewire-pulse isn't up yet, `pactl subscribe` fails and the daemon
      # exits CLEANLY (code 0) — on-failure would leave auto-switch dead for
      # the whole session, so restart unconditionally and never hit the start
      # limit.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${tools.auto-mic-daemon-sh}/bin/audio-auto-mic-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };
  };
}
