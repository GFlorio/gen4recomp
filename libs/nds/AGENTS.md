# libs/nds Agent Guidance

Read root `AGENTS.md` first. `libs/nds` owns reusable Nintendo DS, Nitro, and NNS
platform semantics with concrete current consumers. It is an internal package, not a
supported third-party API.

## Ownership

- `rom` owns DS cartridge containers and FNT/FAT/overlay structures.
- `nitro/g3d` owns NNS G3D resource formats and their platform semantics.
- `gx` owns DS 3D registers, raster state, and related plain frame data.
- `nitro/sound` owns SDAT/SSEQ/SBNK/SWAR/SWAV formats and NNS player/channel semantics.
- `love` owns the concrete LÖVE implementation of the DS-shaped renderer.

Pure format and semantic subpackages must not require `love`; host-specific code belongs
under `love` and may depend on the platform semantics below it.

## Dependency direction

NDS code may depend on `libs/codec`, `libs/errors`, and `libs/math` when a concrete
platform responsibility requires them. It must not depend on `libs/assets`, `libs/script`,
`libs/hgss`, `game`, or `romdump`. Project asset schemas, HGSS policy, application policy,
and ROM provisioning remain above this package.
