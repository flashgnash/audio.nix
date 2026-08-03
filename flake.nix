{
  description = "PipeWire audio stack: RNNoise denoised virtual source, hot-plug mic combiner, Firefox screen-audio";

  inputs = {
    pipewire-screenaudio.url = "github:IceDBorn/pipewire-screenaudio";
  };

  outputs =
    { self, pipewire-screenaudio, ... }:
    {
      nixosModules = {
        # Fully wired — the pipewire-screenaudio dependency is bound to this
        # flake's own input, so consumers just add the module; no specialArgs
        # plumbing required.
        pipewire = import ./pipewire.nix pipewire-screenaudio;

        default = self.nixosModules.pipewire;
      };
    };
}
