# ADR: field-actor visual representation

**Status:** Accepted
**Date:** 2026-08-05
**Scope:** how a HGSS field actor's ROM graphics become runtime-drawable data,
and what `g4-field-actor-v1` contains

## Context

A field actor's `spriteId` is not an archive member. Resolving one to drawable
data goes through four tables, all of which live in ARM9 overlay 1 or in the
`mmodel` archive (`a/0/8/1`):

```text
spriteId
  -> six-byte graphics record        u16 spriteId, u16 mapModelId, u16 packed
       mapModelId                    -> the actor's own NSBTX member
       packed bits 10-15             -> visual descriptor index
  -> eight-byte visual descriptor    u8 modelKey, u8 timelineKey, ptr ranges
       modelKey    -> key table      -> shared NSBMD member (266 for every
                                        target class)
       timelineKey -> key table      -> timeline `.bin` member
       ranges                        -> 12-byte animation ranges, one per
                                        direction in the order N, S, W, E
```

The shared model member is a single 32x32 quad (`mmdl_m32x32`) with a
bottom-center local origin, drawn through the Nitro `NNS_G3D_SBC_BB` command --
a full camera-facing billboard, not a world-upright one. The actor loader
supplies unit scale and adds six model units to Y before drawing. The timeline
maps animation time to a `(textureSlot, paletteSlot)` pair inside the actor's own
NSBTX; walking advances the clock one frame per field update, and idle does not
advance it at all, so an idle actor holds the first slot of its facing range.

The question this ADR settles is whether the runtime should carry Nitro model
and texture state and animate it, or whether the compiler should normalize the
reachable frames into a generated image.

## Decision

**`renderKind = "atlas"`.** For each selected sprite the importer decodes exactly
the `(textureSlot, paletteSlot)` pairs its animation ranges can reach, packs them
into one horizontal 32-pixel-tall RGBA strip, and emits a `g4-field-actor-v1`
definition whose poses reference strip frames.

This is not an approximation. The original draws one textured quad; a strip frame
is that quad's texture. The atlas is lossless for this actor class.

| Criterion | Atlas | Runtime NSBMD/NSBTX |
| --- | --- | --- |
| Fidelity for these actors | Lossless -- the source is one textured quad | Lossless, but adds no capability |
| Direction and timing | Recovered slot sequences and thresholds stored directly | Still needs the same custom timeline |
| Renderer fit | Ordinary image/quad path; simple batching and disposal | Carries Nitro model state into gameplay |
| Debuggability | Private PNG plus a declarative manifest | Needs a specialized preview path |
| Scope risk | Bounded | Risks becoming a general field-model animation subsystem |

The schema keeps every source fact the atlas discards -- member IDs, packed
subfields, texture and palette slots, per-frame tick counts, source frame ranges,
end modes, and the billboard mode -- so a later actor class that genuinely needs
non-quad geometry can be added as a second `renderKind` without reshaping the
data that already works.

### `g4-field-actor-v1`

```lua
{
  schema = "g4-field-actor-v1",
  spriteId, mapModelId, rawGraphicsFlags,
  original = { movementProfile, actorFamily, visualDescriptor },
  render = {
    kind = "atlas", image, frameWidth, frameHeight, frameCount,
    billboardMode = "cameraFacingFull", mirrorEastWest = false, alphaUsage,
  },
  anchor = { x = 0, y = 6, z = 0 },      -- source model units
  bounds = { width = 32, height = 32, depth = 0 },
  pivot  = { x = 0.5, y = 1.0 },         -- bottom center, in atlas terms
  frames = { { textureSlot, paletteSlot }, ... },   -- atlas order
  directions = {
    north = { idle = Pose, walk = Pose }, south = ..., west = ..., east = ...,
  },
  directionalSet2 = { north = Pose, ... } or nil,
  source = { archive, modelMemberId, textureMemberId, timelineMemberId,
             modelKey, timelineKey, graphicsRecordOffset, ...Sha1 },
}

Pose = {
  frames = { { frameIndex, ticks }, ... },
  loop, durationTicks,
  sourceRange = { startFrame, endFrame, endMode },
}
```

Deliberate choices inside the schema:

- **Per-frame `ticks`, not a single `ticksPerFrame`.** The static Marill's
  south-facing loop is 5/10/5 ticks. A uniform frame length would silently
  corrupt it, and future actors may animate palettes on their own cadence.
- **`frameIndex` into a compacted strip, with the raw slots preserved.** Two
  directions that display the same source slot share one atlas frame; `frames`
  still records which `(textureSlot, paletteSlot)` produced it.
- **`directionalSet2` under a neutral name.** Player descriptors carry eight
  ranges. The slots and timing of the second set are recovered exactly, but the
  gameplay state that triggers it has not been traced, so it is not called
  "run" until the movement work proves what it is.
- **`idle` is derived, not stored separately in the ROM.** It is the first
  displayed frame of the direction's own range, because an idle actor never
  advances its animation clock.
- **No east/west mirroring.** The source uses distinct texture slots for east
  and west, and the private test asserts they differ.

## Validation

Every mapping is read from the ROM. There is no `spriteId -> member` table, and
no `modelKey`/`timelineKey` table, in the repository: the graphics table, the
descriptor table, and both key tables are parsed out of overlay 1 at import time
using the load address the ROM's own overlay table reports. `data/manifests/field_actors.lua`
carries only original runtime addresses and the invariants to check them against.

Validated against the canonical US HeartGold dump:

| Fact | Value |
| --- | --- |
| Overlay 1 load address | `0x021E5900` (compressed in the FAT, 148064 bytes loaded) |
| Graphics table offset | `0x21BA8` (`0x022074A8` runtime) |
| Non-terminator records | 901, no duplicate `spriteId` |
| Terminator | at `+0x151E`; logical span 5412 bytes |
| Shared model member | 266, `BMD0` |
| Timelines | 280 (ordinary), 281 (player), 292 (static Marill) |
| Actor textures | one `BTX0` member per sprite, 32x32 `palette16`, color 0 transparent |

The private suite (`scripts/test-private.sh`) asserts the table invariants, the
per-sprite source bundle for all eleven target classes, the absence of
`SPRITE_VAR_1`, the range counts that distinguish player from ordinary
descriptors, Marill's uneven loop, and byte-reproducible compilation.
`scripts/inspect-actors.sh` prints the same facts without writing anything, and
`scripts/actor-preview.sh` renders all four directions and the animated walk for
every compiled sprite with a ground line at the pivot.

## Packed graphics flags

The packed word is fully partitioned; no bit is unclassified.

| Bits | Meaning | Handling |
| --- | --- | --- |
| 0-4 | movement/terrain response profile | preserved as `original.movementProfile`; behavior, not an asset selector |
| 5-9 | map-object callback family | preserved as `original.actorFamily`; behavior, not an asset selector |
| 10-15 | visual descriptor index | the asset selector, compiled now |

The whole word is also kept verbatim as `rawGraphicsFlags`.

## Consequences

- The runtime never parses a Nitro model or texture. `FieldActorAssetProvider`
  loads a PNG and a Lua definition and hands out reference-counted entries.
- Actor visuals are an independently rebuildable derived class: changing the
  actor compiler rebuilds `data/generated/field/actors` and
  `assets/generated/field/actors` and leaves compiled maps and the raw dump
  alone.
- Rendering must reproduce a **full camera-facing** billboard. Anything that
  keeps world up fixed will not match the original at the pitches the field
  camera uses; the six-unit Y offset is stored in source model units and is
  converted at draw time, not baked into the image.
- A future actor class that is not a single quad needs a new `renderKind`, not a
  reshaped schema.
