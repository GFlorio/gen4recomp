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
   assets: `g4-map-scene-v3` descriptors, `G4M2` mesh batches, and PNG textures.
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

## Billboards

An SBC `BB` command installs a position matrix that depends on the camera, so its
shapes cannot be baked. Such a batch is compiled with `transformMode =
"billboard"` and a `baseTransform`: the position matrix the command captured,
with its translation converted to tiles, and geometry left in billboard-local
space. `MapSceneLoader` composes that base with the placement transform;
`MapRenderer` calls `BillboardTransform.resolve` once per draw per frame, before
the queue is built, so `u_model`, the normal matrix, translucent sorting, and
every pass share one matrix.

Following NitroSystem `sbc.c`, the resolved matrix keeps the base translation and
the magnitude of each base basis vector and discards the base rotation:

```text
translate(base translation) * inverse(view rotation) * scale(base scale)
```

It is not a lookAt, and full `BB` responds to camera pitch as well as yaw. `BBY`
(yaw only) is not implemented: no model in the target ROM issues one. One
billboard matrix covers a whole shape, so a billboard display list that restores
a matrix mid-stream raises
`MAP_COMPILE_BILLBOARD_MATRIX_RESTORE_UNSUPPORTED`; none in the ROM does.

## Field actors

Field actors are world geometry, not a 2D overlay. Ordinary actors use the shared
`mmodel` model member's single quad, replayed at import time through the same
`MeshCompiler` the map and building models use, so its vertices (in tiles), its
normal, its vertex-colour source, its UVs, its `BB` base transform, and its
effective `POLYGON_ATTR` all come from the ROM. `FieldActorMesh` builds one mesh
per atlas frame -- identical geometry with the U range slid onto that frame --
and `FieldActorDraw` turns a presentation-neutral `ActorDrawRecord` into a draw
item whose `billboardBase` is the actor's world placement composed onto that base
transform. Static map-object actors instead retain each NSBMD geometry and
polygon-state part and draw without a billboard transform. Pose selection
(`FieldActorPose`) is independent of both paths.

The state the ordinary shared model declares (asserted per original target class
by the private suite):

| Fact | Value | Consequence |
| --- | --- | --- |
| Quad | 4 vertices, 2 x 2 tiles, bottom-centered, zero depth | placed by the actor's feet |
| Anchor | 6 model units on Y, i.e. 0.375 tiles | applied at draw time, never baked into the atlas |
| Billboard | Nitro `BB`, full camera-facing | the sprite never foreshortens with camera pitch |
| Polygon alpha | 31, modulation mode, single-sided (`back` cull) | ordinary opaque-pass ordering |
| Texture | 32x32 `palette16`, colour 0 transparent | classified `cutout`, so the shader discards alpha-zero fragments |
| Vertex colour source | `NORMAL` with light mask 1 | the field light profile shades actors like map geometry |
| Polygon ID | 0 | actor polygons take part in edge marking with the same ID map terrain uses |

Because the quad is camera-facing, its whole surface sits at the pivot's view
depth: it depth-tests against map geometry as a flat card at the actor's own
distance, which is what makes walls and foreground geometry occlude it correctly.
A world-upright quad would instead be squashed by the camera pitch --
`scripts/field-shot.sh` captures make the difference obvious.

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
* `BB` billboards, resolved per frame from the captured base transform.
* `NODEMIX` position blending through the joints' inverse bind poses. Its normal
  blend is not computed separately: it follows from the position blend while each
  bind pose is rigid, which the compiler checks per joint and raises
  `NSBMD_STATIC_NODEMIX_NONRIGID_BIND_POSE` if violated.
* Scene v3 / G4M2 / cache v5 explicit versioning and invalidation.

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
* `BBY` yaw-only billboards, `CALLDL` external display lists, non-rigid `NODEMIX`
  bind poses, and the Si3D scaling rule.

Unsupported polygon modes (`toon`, `shadow`) and in-display-list local
light/shininess commands fail compilation with:

* `MAP_COMPILE_UNSUPPORTED_POLYGON_MODE`
* `MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED`
* `MAP_COMPILE_SHININESS_UNSUPPORTED`

## Cache invalidation

Derived map caches carry explicit versions:

```lua
MapAssetCache.FORMAT              = "map-cache-v5"
MapAssetCompiler.COMPILER_VERSION = "map-compiler-v14"
scene.schema                      = "g4-map-scene-v3"
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

Set `G4RECOMP_FIELD_TIME=<seconds>` to override the default noon time.

Known discrepancies to record: no BDHC height (player Y is flat) and the
deferred behaviors listed above. The diagnostic uses the exact ROM-derived
camera profile for each map.

Field-camera projection, adaptive aspect behavior, zoom tuning, safe-area
policy, and camera-specific parity gaps are documented in
[field-camera.md](field-camera.md).
