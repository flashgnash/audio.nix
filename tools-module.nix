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
    # when they actually underrun and decays it when quiet. ON by default;
    # opting OUT drops the disable flag file (audio-xrun-guard-toggle manages
    # it) and ConditionPathExists makes the choice persist across logins.
    systemd.user.services.audio-xrun-guard = {
      description = "USB audio xrun guard (auto headroom)";
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      unitConfig.ConditionPathExists = "!%E/qs-audio-xrun-guard-disabled";
      serviceConfig = {
        ExecStart = "${tools.audio-xrun-guard-sh}/bin/audio-xrun-guard";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

    # Bluetooth mic release: returns a BT headset to A2DP once its mic is idle,
    # so it never gets stranded in low-quality HFP/HSP after use. Event-driven
    # off pactl subscribe; an active call keeps the source RUNNING and is spared.
    systemd.user.services.audio-bt-mic-release = {
      description = "Release idle Bluetooth headset mics back to A2DP";
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
        ExecStart = "${tools.bt-mic-release-sh}/bin/audio-bt-mic-release";
        Restart = "always";
        RestartSec = "3s";
      };
    };

    # Mic mix-sync daemon: keeps a fixed-delay `delayed.<mic>` wrapper per
    # physical mic and auto-measures the delays (speech cross-correlation) so
    # MIX mode mixes in-phase. combined_mics captures these wrappers — with
    # this service down, MIX mode has no inputs (single-mic mode unaffected).
    #
    # Tied to pipewire.service, NOT graphical-session.target: the mic chain
    # must work in any session that has PipeWire — an SSH-only boot (greeter
    # never logged in) left combined_mics with zero capture streams because
    # graphical-session never activated (2026-10-07). partOf also restarts
    # the daemon with PipeWire, replacing a dead `pactl subscribe` promptly.
    systemd.user.services.audio-mix-sync = {
      description = "Microphone mix time-alignment (auto-measured delays)";
      after = [
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "pipewire.service" ];
      wantedBy = [ "pipewire.service" ];
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

    # Echo-cancel auto-toggle: bypasses the AEC stage on headphones (where
    # webrtc suppresses the near-end voice instead of echo) and re-enables it
    # when the default output is a speaker-class sink. Event-driven off pactl
    # subscribe.
    systemd.user.services.audio-aec-auto = {
      description = "Echo-cancel auto toggle (speakers on, headphones off)";
      # pipewire-tied like audio-mix-sync: AEC routing must be right in any
      # session with PipeWire, not just desktop logins (2026-10-07).
      after = [
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "pipewire.service" ];
      wantedBy = [ "pipewire.service" ];
      # If pipewire-pulse isn't up yet `pactl subscribe` fails and the daemon
      # exits; restart unconditionally rather than trip the start limit.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${tools.aec-auto-daemon-sh}/bin/audio-aec-auto-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };

    # Auto-switch microphone daemon. Idle (spawns nothing) until the config
    # at ~/.config/auto-mic/config.json enables it with >=2 candidate mics.
    systemd.user.services.auto-mic = {
      description = "Automatic microphone switcher (VAD-driven)";
      # pipewire-tied like audio-mix-sync: mic selection must work in any
      # session with PipeWire, not just desktop logins (2026-10-07).
      after = [
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "pipewire.service" ];
      wantedBy = [ "pipewire.service" ];
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

    # Automix daemon — gain-based successor to the auto-mic switcher (static
    # graph, per-group priority gating; see automix-daemon-py in tools.nix).
    # Idle until ~/.config/audio-automix/config.json enables it. Runs
    # alongside auto-mic during the migration: enabling automix suspends the
    # legacy switcher (and restores it on disable), so the two never fight.
    systemd.user.services.audio-automix = {
      description = "Microphone automix (per-group VAD priority gating)";
      # pipewire-tied like audio-mix-sync: gain gating must work in any
      # session with PipeWire, not just desktop logins (2026-10-07).
      after = [
        "pipewire.service"
        "wireplumber.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "pipewire.service" ];
      wantedBy = [ "pipewire.service" ];
      # Same rationale as auto-mic: a too-early `pactl subscribe` exits
      # cleanly, so restart unconditionally with no start limit.
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        ExecStart = "${tools.automix-daemon-sh}/bin/audio-automix-daemon";
        Restart = "always";
        RestartSec = "3s";
      };
    };
  };
}
