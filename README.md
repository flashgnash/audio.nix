# Audio modules

Self-contained flake with the PipeWire audio stack:

- **`pipewire`** (also **`default`**) — PipeWire + WirePlumber with:
  - **RNNoise denoised virtual source** (`rnnoise_source`): the whole audio
    stack lives behind one virtual mic. Denoising is bypassed *in-graph* via
    a dry/wet mixer (flip `Gain 1`/`Gain 2` on the filter-chain node with
    `pw-cli set-param <id> Props`), so toggling the filter never switches
    devices out from under apps. VAD tuned to gate hallucinated noise while
    a 700ms grace period keeps speech from clipping.
  - **Hot-plug mic combiner** (`combined_mics`): every physical mic (ALSA +
    bluetooth) mixed into one mono virtual source via combine-stream rules;
    per-mic levels adjustable as recording streams. Latency compensation is
    deliberately off (wireless dongles report bogus latencies).
  - **Firefox with pipewire-screenaudio** native messaging host, for sharing
    system audio in screen captures (note: this overrides the firefox
    package — omit or override if you build firefox differently).
  - rtkit, ALSA (+32-bit), PulseAudio emulation, noisetorch.

## Usage

```nix
{
  inputs.audio.url = "github:flashgnash/audio.nix";

  outputs = { nixpkgs, audio, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        audio.nixosModules.default
        # ... your other modules
      ];
    };
  };
}
```

## Notes

- Do NOT add a static `combine-stream` output duplicator to this config: with
  passive device streams the sinks never wake (apps playing into it hang);
  with active ones every sink runs from boot, which can wedge a USB sink in
  a permanent XRUN (no audio at all). Load `module-combine-sink` via
  pipewire-pulse (`pactl load-module`) on demand instead, and unload it when
  done.
- The combiner's match regexes must only ever hit hardware inputs — matching
  another `Audio/Source` like `rnnoise_source` creates a feedback loop.
