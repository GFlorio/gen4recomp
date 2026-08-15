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
   assets: `g4-map-scene-v7` descriptors, `G4M2` mesh batches, and PNG textures.
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

## Vertex lighting contract

The per-vertex color is the DS geometry-engine formula (GBATEK "Internal
Operation on Normal Command"; the fixed-point domain from melonDS
`GPU3D::CalculateLighting`):

```text
VertexColor = Emission + Sum_i( LightColor_i * (Ambient + Diffuse*ld_i + Specular*ls_i) )
```

summed per RGB channel over the lights enabled by the polygon's `lightMask`,
where `ld = max(0, -dot(L, N))` (the profile light vectors point in the
direction the light travels, from source toward surface) and `ls` is the
melonDS `cos(2a)` term `clamp(2*ndh^2 - 1, 0, 1)` with
`ndh = max(0, dot(N, H))`, `H = normalize(-L + (0,0,1))` in camera/vector
space, gated on the front-light test `ld > 0` (`dot(-L,N) > 0`) exactly like
the hardware (GPU3D.cpp `CalculateLighting`; DeSmuME computes the same
`2*dot^2-4096`). Ambient is not gated: melonDS adds it for every enabled
light regardless of the light/normal dot. There is no shininess-table path:
the table is global GX state (SPE_EMI bit 15) and the ROM census found no
HGSS field material setting the bit.

The numeric domain is the important part: the DS hardware multiplies its RGB555
colors as fractions of full scale (fixed point), not as saturating integers, so
a dim light dims a bright material proportionally. Both implementations
therefore work in normalized 0..1 (RGB555 color / 31, fx12 vector / 4096), and
both quantize the clamped result to 5 bits by truncation
(`floor(c*31)`), matching the hardware, which truncates its fixed-point
accumulator (a single full-intensity light caps at 30/31 per channel).

The vertex shader (`libs/engine/src/shaders/map.glsl`) is the rendered form of
this contract, and `libs/engine/src/DsLighting.lua` is its pure-Lua reference;
`ds_lighting_test` asserts they agree at midrange colors and angles.

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

Materials carry the texture, wrap/flip, and a diffuse color retained for
modulation/decal semantics. Terrain scene materials additionally carry their
texture-matrix inputs (`texWidth`, `texHeight`, `texMtxMode`, and the
normalized static `srt`), and, when the map's `fldtanime` table animates them,
a `textureSwap` replacement schedule.

## Terrain animation

Terrain texture animation is compiled into the scene descriptor and driven at
field time by `TerrainMaterialAnimator`:

* `material.texture` is the initial terrain image the map binds at load.
* `material.textureSwap = { name, steps }` is the replacement schedule:
  each step references the image HGSS uploads on entering that schedule entry,
  with its `durationTicks`. The initial `material.texture` is not part of the
  schedule; step images are swapped in only when a step's duration expires.
* Terrain texture SRT (the area NSBTA clip) is initialized at scene load from
  frame zero and re-sampled once per fixed tick; a material without a clip
  target keeps its static `srt` matrix.

The asset cache validates the generated schedule (including that same-name
schedules agree across central and neighbor cells) and that terrain
`texMtxMode` is `0`.

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

The RGB fragment combiner is the DS integer-domain equation (GBATEK's
MODULATE/DECAL blending modes; `libs/engine/src/DsFragment.lua` is the pure
reference, `map.glsl`'s `modulateRgb6`/`decalRgb6` its GLSL transcription),
not floating-point multiplication. Both the texture sample and the vertex
color enter as 5-bit (0-31) components, widened to the combiner's 6-bit
(0-63) domain by hardware bit-replication (`expand5to6`: `c5*2 +
floor(c5/16)`). MODULATE is
`floor(((texture6+1)*(vertex6+1)-1)/64)` per channel. DECAL keeps the
polygon alpha as output alpha and blends RGB by the texel's own alpha:
texture alpha 0 keeps the vertex color, 31 keeps the texture color,
otherwise the two interpolate by that alpha. An untextured polygon samples
`vec4(1.0)`, which is exactly `DsFragment.syntheticTexture()`'s (63,63,63,31)
after quantization -- the identity element of both equations, so no separate
synthetic-texture uniform exists.

The shader composes 5-bit alpha as:

```text
Aout5 = floor((((At5 + 1) * (Ap5 + 1)) - 1) / 32)
```

For decal mode the resulting alpha is the polygon alpha. Cutout draws discard
when the final 5-bit alpha is zero, implemented as `alpha < 0.5 / 255`.

## Render passes

`RenderQueue` partitions draws into opaque / cutout / translucent / wireframe.
Opaque and cutout keep submission order with depth test/write. Translucent draws
are sorted back-to-front in view space (submission position breaks ties) and honor
the polygon bit-11 translucent depth-write flag. Wireframe edges are drawn with
opaque alpha after the filled passes. `FieldState` supplies ordered arrays of
map geometry, buildings, neighbour-ring draws, and actors. `RenderQueue`
traverses those parts with one monotonically increasing submission position,
so cross-part tie ordering is established without flattening or stamping the
draw items. `MapRenderer` owns and reuses the queue scratch arrays.

## Edge marking

HGSS field rendering enables DS edge marking with two real per-area color
tables (`romdump.src.digest.HgssFieldEdgeColors.TABLE_A`/`TABLE_B`, each eight
RGB555 entries), selected by `AreaData.lightTypeRaw`: zero selects table A,
non-zero selects table B. `MapAssetCompiler` resolves the table once per area
into `scene.edgeColors`, a required scene field (not a `MapRenderer`
constructor invariant); the renderer caches the table by reference and only
resends `u_edgeColors` when the active scene's table changes.

The edge predicate is the DS rule, not a linear-eye-space heuristic: a pixel
is an edge when an orthogonal neighbor's polygon ID differs from the
center's AND the center is strictly in front of that neighbor
(`DsEdgeMarking.isEdgePixel`, table-indexed by `centerPolygonId >> 3`). The
compared depth is `DsDepth`'s quantized 24-bit domain, derived from the same
W-buffer-shaped value the shader also stores; there is no
`DEPTH_STEP_TOLERANCE` fudge factor. An edge pixel's output is hardware-style
RGB replacement (`vec4(edgeColor, scene.a)`), never an alpha-mix with the
scene color, and there is no separate edge-opacity uniform.

The opaque polygon ID, the DS-quantized depth, and translucent identity are
three independent logical attributes, carried as separate channels of one
`rgba32f` attachment (R = polygon ID, G = depth, B = translucent flag) rather
than one value overloaded to mean several things. In particular, a
translucent fragment's real polygon ID survives (used by later
self-blend-rejection work), never replaced by an invented sentinel ID.

## Billboards

An SBC `BB` command installs a position matrix that depends on the camera, so its
shapes cannot be baked. Such a batch is compiled with `transformMode =
"billboard"` and a `baseTransform`: the position matrix the command captured,
with its translation converted to tiles, and geometry left in billboard-local
space. `MapSceneLoader` composes that base with the placement transform and
stores its translation and basis scales; the vertex shader supplies the
camera-facing axes. `RenderQueue` uses the same center and scale for translucent
sorting. Only the exceptional straddling path calls `BillboardTransform.resolve`.

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
transform, with its center and basis scales precomputed by the actor asset
provider. Static map-object actors instead retain each NSBMD geometry and
polygon-state part and draw without a billboard transform. Pose selection
(`FieldActorPose`) is independent of both paths.

The state the ordinary shared model declares (asserted per original target class
by the ROM-gated layer):

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
A world-upright quad would instead be squashed by the camera pitch.

HGSS does not draw those billboards through the same projection as the map.
After maps and props, `ov01_021E6220` (pokeheartgold `src/field/fieldmap.c`)
copies the active projection, bumps `_32` (the Z-row translation) by `_22` (the
Z-row scale) times `fieldSystem->unk11C = 8` model units times
`cos(-camera.angle.x)`, renders field effects and `BillboardLists_Draw`, then
restores the projection before the remaining 3D objects. The pull stays inside
the depth row, so billboards keep their screen position and size but win depth
ties against same-depth props (signs, mailboxes); 8 model units is 0.5 tiles
here. `FieldCamera:billboardProjection()` reproduces the matrix, and
`FieldActorDraw` flags ordinary actor quads with it so `MapRenderer` binds it
per draw; map/building billboards render in the map pass and static-model
actors draw with the world projection, exactly as on the DS.

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
* MODULATE/DECAL fragment combiner in the DS integer domain, not floating
  multiplication (see "Alpha classification and fragment contract" above).
* The real HGSS field edge-color tables, per-area table selection, the
  strict DS edge predicate/depth representation, RGB-replacement edge
  compositing, and the three-way opaque-ID/depth/translucent-identity
  attribute split (see "Edge marking" above).
* Mirrored texture repeat (`TEXIMAGE_PARAM` flip bits), mapped to LÖVE's
  `mirroredrepeat` wrap mode.
* Global DS fog: the two-gate (`DISP3DCNT` + per-polygon `FOG_ENABLE`) rule,
  the 32-entry density table, and the post-combiner blend (`DsFog.lua`,
  applied in `map.glsl` from the same DS-quantized depth the edge pass
  reads). The per-area/time-of-day source of the fog color/table/offset
  themselves is not: see "Deferred / approximate."
* `BB` billboards, oriented in the vertex shader from the captured base transform.
* The field-billboard depth bias (`unk11C = 8` model units in `ov01_021E6220`):
  actor billboards render through a projection whose Z row is pulled
  0.5 · cos(pitch) tiles toward the camera, so they win same-depth ties.
* `NODEMIX` position blending through the joints' inverse bind poses. Its normal
  blend is not computed separately: it follows from the position blend while each
  bind pose is rigid, which the compiler checks per joint and raises
  `NSBMD_SBC_NODEMIX_NONRIGID_BIND_POSE` if violated.
* Building/model animation (NSBCA joints, NSBTP pattern, NSBMA color, NSBTA
  texture SRT) through the dynamic-model path and `MaterialEvaluator`, including
  door roles and the time-of-day banded clips.
* Terrain texture swap and terrain texture SRT (see "Terrain animation"),
  stepped at fixed-tick time by `TerrainMaterialAnimator`.
* Scene v5 / G4M2 / cache v7 explicit versioning and invalidation.

### Deferred / approximate

These are documented rather than silently approximated. If a target map needs
one, the compiler raises a structured error instead of rendering incorrectly.

* Polygon-ID same-ID translucent self-blend rejection: `DsBlend.rejectsSelfBlend`
  defines the rule, but the renderer does not implement it (no auxiliary
  compositor exists, and no corpus content has been found to produce that
  overdraw pattern).
* Exact DS automatic translucent Y sorting: HGSS field content is confirmed
  (via decomp) to genuinely use `GX_SORTMODE_AUTO`, but the exact hardware
  vertex-selection rule was never independently confirmed against melonDS, so
  the renderer keeps the pre-existing approximate object-center-Z
  back-to-front sort rather than tuning an unconfirmed rule.
* Destination-alpha (`max(SrcAlpha, DstAlpha)`): the RGB blend equation
  itself already matches `DsBlend.blendRgb6`'s shape, but nothing downstream
  reads the scene color's alpha channel, so this part of the contract is
  unimplemented and currently unobservable.
* Per-area/time-of-day fog color/table/offset source data: the fog gate,
  table, and post-combiner math are implemented exactly (see "Implemented
  exactly" above), but no decompiled reference in this checkout identifies
  where HGSS selects them per area/weather, so the renderer sends the DS
  SDK's real idle-default fog state (disabled, black, zero table, zero
  offset) globally rather than live per-area data.
* `depthEqual`/`translucentDepthWrite`: never exercised anywhere in the
  target field corpus; `PolygonState.validate` raises
  `POLYGON_STATE_DEPTH_EQUAL_UNSUPPORTED` rather than approximating the DS
  Z/W "equal" tolerance with the host's `lequal` compare.
* Shadow polygons and the `toon`/`highlight` polygon modes: absent from the
  full HeartGold field corpus census (every material resolves to
  `modulation`); compilation fails with `MAP_COMPILE_UNSUPPORTED_POLYGON_MODE`
  rather than silently approximating one if a future dump introduces it.
* Wireframe polygon-perimeter geometry: the true GX polygon perimeter
  (excluding triangulation diagonals) is captured at the romdump layer
  (`GxDisplayList.polygonEdges`), but it is not yet wired into the mesh
  compiler or renderer -- wireframe draws still use
  `love.graphics.setWireframe(true)` over triangulated geometry, so triangle
  diagonals remain visible on the rare wireframe shapes the corpus contains.
  Closing this needs a CPU-side `love.graphics.line()` per-edge draw path,
  since LÖVE 11.5's Mesh API has no line-drawing primitive.
* Exact fixed-point clipping/raster interpolation.
* Local shininess-table rendering (table data is parsed but not used).
* `BBY` yaw-only billboards, `CALLDL` external display lists, non-rigid `NODEMIX`
  bind poses, and the Si3D scaling rule.

Unsupported polygon modes (`toon`, `shadow`) and in-display-list local
light/shininess commands fail compilation with:

* `MAP_COMPILE_UNSUPPORTED_POLYGON_MODE`
* `MAP_COMPILE_LOCAL_LIGHT_OVERRIDE_UNSUPPORTED`
* `MAP_COMPILE_SHININESS_UNSUPPORTED`

## Cache invalidation

Derived map caches carry the persisted format/schema identities:

```lua
MapAssetCache.FORMAT              = "map-cache-v7"
scene.schema                      = "g4-map-scene-v7"
terrain.schema                    = "g4-terrain-surfaces-v1"
collision version                 = 1
VertexFormat.VERSION              = 2
```

These values describe persisted contracts and live in
`DerivedAssetContract`; there are no compiler-version literals. Implementation
freshness is owned by the `romdump/src` producer fingerprint: any producer
change forces one complete derived rebuild, so a stale cache can never
masquerade as current. The dependency record also includes the field-light
source SHA-1, ROM SHA-1, and member SHA-1s. `MapAssetCache.isReady` rejects any
marker mismatch or missing referenced file, so a damaged cache repairs from the
raw dump rather than loading old data.

Old scene schemas (`g4-map-scene-v1`) and mesh versions (`G4M1`) are rejected
explicitly with `MAP_SCENE_UNSUPPORTED_SCHEMA` and `MESH_BAD_VERSION`.

Field-camera projection, adaptive aspect behavior, zoom tuning, safe-area
policy, and camera-specific parity gaps are documented in
[field-camera.md](field-camera.md).
