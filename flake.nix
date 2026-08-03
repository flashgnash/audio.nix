{
  description = "PipeWire audio stack: RNNoise denoised virtual source, hot-plug mic combiner, Firefox screen-audio";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pipewire-screenaudio.url = "github:IceDBorn/pipewire-screenaudio";
  };

  outputs =
    {
      self,
      nixpkgs,
      pipewire-screenaudio,
      ...
    }:
    {
      # Standalone tools (audio-* + audioctl) for non-NixOS-module use:
      #   nix run github:flashgnash/audio.nix -- rnnoise-toggle
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: rec {
        audio-tools = (import ./tools.nix { pkgs = nixpkgs.legacyPackages.${system}; }).audio-tools;
        default = audio-tools;
      });

      nixosModules = {
        # Fully wired — the pipewire-screenaudio dependency is bound to this
        # flake's own input, so consumers just add the module; no specialArgs
        # plumbing required.
        pipewire = import ./pipewire.nix pipewire-screenaudio;

        # audio-* CLI tools + audioctl dispatcher + the xrun-guard/auto-mic
        # user daemons. Any UI can be built over these; gate on
        # `programs.audioctl.enable` (osConfig from home-manager).
        tools = import ./tools-module.nix;

        default = {
          imports = [
            self.nixosModules.pipewire
            self.nixosModules.tools
          ];
        };
      };
    };
}
