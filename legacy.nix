# The legacy audio stack's switch (flakes/audio: ./pipewire.nix and
# ./tools-module.nix, module-sets' legacy-audio-modules). Imported by each of
# them, so a host has it exactly when some of the legacy stack is present;
# home-manager modules read it as `osConfig.audio.legacy.enable or false`
# (EasyEffects, the legacy quickshell audio panel).
{ config, lib, ... }:
{
  options.audio.legacy.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      The legacy PipeWire audio stack: its filter chain and mic combiner,
      audioctl and its daemons, noisetorch, and (through home-manager)
      EasyEffects and the legacy quickshell audio panel. On wherever its
      modules are imported. It and chainmail (`services.chainmail.enable`)
      can't both be on.
    '';
  };

  config.assertions = [
    {
      assertion =
        !(
          (config.audio.legacy.enable || (config.programs.audioctl.enable or false))
          && (config.services.chainmail.enable or false)
        );
      message = "The legacy audio stack (legacy-audio-modules: audio.legacy.enable, programs.audioctl.enable) and chainmail (services.chainmail.enable) can't both be on: they would fight over the PipeWire graph. Turn one of them off.";
    }
  ];
}
