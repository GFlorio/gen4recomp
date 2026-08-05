# DS material, lighting, and rendering

This document describes how g4recomp turns HGSS map/building models into a
drawable runtime scene. It covers the normalized data contracts, the path from
raw Nitro formats to GPU draws, and exactly which DS behaviors are reproduced
versus deferred.

## Overview

The pipeline has four stages:

1. **Parse** raw Nitro formats (`Nsbmd`, `Nsbtx`, `GxDisplayList`) independently
   of LÖVE.
2. **Compile** a map + its placed buildings into derived, content-addressed
   assets: `g4-map-scene-v2` descriptors, `G4M2` mesh batches, and PNG textures.
3. **Load** the derived cache into runtime GPU objects (`MapSceneLoader`).
4. **Draw** with the DS-shaped shader and render queue (`MapRenderer`).

A field-time change updates only uniforms; it never reparses, recompiles, or
rebuilds meshes.

## Field-light profiles

HGSS stores time-of-day lighting in plain-text tables under NitroFS:

```text
data/area00light.txt  -- New Bark / outdoor daytime
data/area01light.txt  -- indoor (e.g. Elm's Lab)
data/area02light.txt  -- evening / dusk
data/dun20_01light.txt
data/dun20_02light.txt
```

`AreaData.lightTypeRaw` selects the profile via `HgssFieldLighting.resolve`:

| `lightTypeRaw` | profile | path |
| --- | --- | --- |
| 0 | 1 | `data/area01light.txt` |
| 1 | 0 | `data/area00light.txt` |
| 2 | 3 or 4 | dungeon variants |

Each profile is a sequence of records. One record is:

```text
startHalfSeconds          -- threshold in half-seconds since midnight
enabled,r,g,b,x,y,z       -- four directional light slots
enabled,r,g,b,x,y,z
enabled,r,g,b,x,y,z
enabled,r,g,b,x,y,z
diffuseR,diffuseG,diffuseB
ambientR,ambientG,ambientB
specularR,specularG,specularB
emissionR,emissionG,emissionB
EOF
```

Selection is cyclic: `halfSeconds = floor((secondsSinceMidnight % 86400) / 2)`,
then pick the last record whose `startHalfSeconds <= halfSeconds`. No
interpolation.

The profile source bytes are SHA-1 hashed and recorded in both the scene
(`scene.lighting.sourceSha1`) and the cache dependencies
(`dependencies.fieldLightSourceSha1`). Changing a profile text file invalidates
the derived cache.

## Normalized material state

`Nsbmd` exposes the exact file bytes. `DsMaterial.resolve` merges a raw material
with explicit HGSS field-global defaults and applies the field-model policy,
which clears model ownership of diffuse/ambient/specular/emission so the field
profile supplies them.

The resolved per-batch polygon state (not the material) carries:

* `polygonAttrRaw`;
* `lightMask`, `polygonMode`, `polygonAlpha`, `polygonId`;
* front/back render flags → `cullMode`;
* `translucentDepthWrite`, `depthEqual`, `farClipEnabled`, `oneDotEnabled`,
  `fogEnabled`.

Materials carry only texture, wrap/flip, and a diffuse color retained for
modulation/decal semantics.

## Vertex color sources and G4M2

Every emitted vertex must have a resolved color source:

| source | value | meaning |
| --- | --- | --- |
| `LITERAL` | 0 | explicit `COLOR` command or a snapshotted diffuse value |
| `NORMAL_LIT` | 1 | vertex produced by a `NORMAL` command; shaded in the vertex shader |
| `FIELD_DIFFUSE` | 2 | current color sourced from the active field-profile diffuse |

The `G4M2` batch format stores this in a 40-byte stride:

```text
+0x00 f32 x, y, z
+0x0C f32 u, v
+0x14 f32 nx, ny, nz
+0x20 u8  r, g, b, a
+0x24 u8  colorSource
+0x25 u8  reserved[3]
```

`VertexFormat.VERSION` is 2; `SceneMesh` rejects older versions.

## Alpha classification and fragment contract

A batch is classified into one of four ordering classes:

| condition | class |
| --- | --- |
| `polygonAlpha == 0` | `wireframe` |
| `polygonAlpha < 31` | `translucent` |
| texture format 1 (A3I5) or 6 (A5I3) | `translucent` |
| texture alpha has zero and no partial | `cutout` |
| otherwise | `opaque` |

The shader composes 5-bit alpha as:

```text
Aout5 = floor((((At5 + 1) * (Ap5 + 1)) - 1) / 32)
```

For decal mode the resulting alpha is the polygon alpha. Cutout draws discard
when the final 5-bit alpha is zero, implemented as `alpha < 0.5 / 255`.

## Render passes

`RenderQueue` partitions draws into opaque / cutout / translucent / wireframe.
Opaque and cutout keep submission order with depth test/write. Translucent draws
are sorted back-to-front in view space (submission index breaks ties) and honor
the polygon bit-11 translucent depth-write flag. Wireframe edges are drawn with
opaque alpha after the filled passes.

## Exact versus approximate behavior

### Implemented exactly (or close enough for the target maps)

* Full `NNSG3dResMatData` prefix parsing.
* Material-owned versus field-global color channel resolution.
* HGSS field-light profile selection and record lookup.
* DS vertex lighting formula in the vertex shader.
* `COLOR` bypasses lighting; `NORMAL` triggers it; `DIF_AMB` bit 15 seeds the
  current color from diffuse.
* Polygon alpha zero → wireframe; alpha 1-30 → translucent.
* A3I5/A5I3 → translucent; binary zero-alpha → cutout.
* Culling from polygon bits 6-7.
* Translucent bit-11 depth writes.
* Scene v2 / G4M2 / cache v2 explicit versioning and invalidation.

### Deferred / approximate

These are documented rather than silently approximated. If a target map needs
one, the compiler raises a structured error instead of rendering incorrectly.

* Polygon-ID same-ID translucent self-blend rejection.
* Exact DS automatic translucent Y sorting (we use approximate back-to-front).
* Exact DS framebuffer blend equation and destination-alpha behavior.
* DS Z/W "equal" tolerance (`depthEqual` maps to `lequal`).
* Fog.
* Shadow polygons.
* Exact fixed-point clipping/raster interpolation.
* Local shininess-table rendering (table data is parsed but not used).
* Animated materials/textures/joints.

Unsupported polygon modes (`toon`, `shadow`) and in-display-list local
light/shininess commands fail compilation with:

* `MAP_COMPILE_UNSUPPORTED_POLYGON_MODE`
* `MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED`
* `MAP_COMPILE_SHININESS_UNSUPPORTED`

## Cache invalidation

Derived map caches carry explicit versions:

```lua
MapAssetCache.FORMAT              = "map-cache-v2"
MapAssetCompiler.COMPILER_VERSION = "map-compiler-v5"
scene.schema                      = "g4-map-scene-v2"
VertexFormat.VERSION              = 2
FieldLightProfile.VERSION         = "field-light-v1"
```

The dependency record also includes the field-light source SHA-1, ROM SHA-1,
member SHA-1s, and decoder/normalizer versions. `MapAssetCache.isReady` rejects
any marker mismatch or missing referenced file, so a stale cache rebuilds from
the raw dump rather than loading old data.

Old scene schemas (`g4-map-scene-v1`) and mesh versions (`G4M1`) are rejected
explicitly with `MAP_SCENE_UNSUPPORTED_SCHEMA` and `MESH_BAD_VERSION`.

## Manual visual validation

When validating locally, capture (but do not commit):

* Elm at noon;
* New Bark at noon;
* New Bark near sunrise;
* New Bark at night;
* a view containing cutout vegetation;
* a view containing variable-alpha material.

Controls in the map diagnostic:

* `WASD` — move the debug player;
* `Q/E` or `PageUp/PageDown` — step time backward/forward by one hour;
* `Esc` — quit.

Set `G4RECOMP_FIELD_TIME=<seconds>` to override the default noon time for an
automated capture, and `G4RECOMP_SHOT=<path>` to save a screenshot and exit.

Known discrepancies to record: no BDHC height (player Y is flat) and the
deferred behaviors listed above. The diagnostic uses the exact ROM-derived
camera profile for each map.
