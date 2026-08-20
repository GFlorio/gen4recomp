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
4. **Draw** with the DS-shaped shaders and render queue (`MapRenderer`).

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

The per-vertex color is a literal transcription of melonDS's
`GPU3D::CalculateLighting`, in its own unnormalized fixed-point domain, not a
continuous formula quantized only at the end:

```text
vtxbuff[c] = MatEmission[c] << 14
per enabled light i (polygon lightMask bit i):
  dot = sum_c( (LightDirection_i[c] * normalTransformed[c]) >> 9 )   -- per-component truncation, before summing
  if dot > 0:
    diffdot = signExtend(dot, 11 bits)
    vtxbuff[c] += (MatDiffuse[c] * LightColor_i[c] * diffdot) & 0xFFFFF
    -- specular reuses dot, folds in the normal's Z, truncate-squares it,
    -- then applies the light's reciprocal (SpecRecip) -- not a half-vector
  vtxbuff[c] += ((MatSpecular[c] * shinelevel) + (MatAmbient[c] << 9)) * LightColor_i[c]
VertexColor[c] = min(vtxbuff[c] >> 14, 31)   -- the only clamp, at the very end
```

summed per RGB channel over the lights enabled by the polygon's `lightMask`.
The bottom 9 bits of each per-component product are discarded before adding,
not after summing all three components and shifting once. Ambient is not
diffuse-gated: melonDS adds it for every enabled light regardless of the
diffuse dot. Specular is melonDS's `dot`/normal-Z/`SpecRecip`/`shinelevel`
sequence, not a conventional Blinn half-vector squared-cosine term -- the two
do not agree over the same inputs. There is no shininess-table path: the
table is global GX state (SPE_EMI bit 15) and the ROM census found no HGSS
field material setting the bit.

The numeric domain is the important part: nothing above is a `/31` or `/512`
normalized division mid-pipeline. The accumulator starts at
`MatEmission << 14` (not a normalized 0..31 value) and stays in that
unnormalized fixed-point domain through every light's contribution; only the
final result is shifted back down (`>> 14`) and clamped to 0..31. Normals and
the transformed light-direction register both live in the geometry engine's
1.0.9 domain (scale 512).

The vertex shader (`libs/engine/src/shaders/map.glsl`) is the rendered form of
this contract. `tests/support/DsLighting.lua` is an independent pure-Lua
transcription of the same melonDS algorithm, used only as a test oracle (no
production code requires it); `ds_lighting_test` checks it against numbers
hand-derived from `GPU3D::CalculateLighting`, and a graphics-smoke test checks
the shader's own rendered output against a separately hand-derived expected
pixel value from that same source algorithm.

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

`AlphaClassifier.classify(polygonAlpha, polygonMode, textureFormat,
alphaUsage)` classifies a batch into one of five ordering classes, driven by
the fragment's own exact final alpha5, never by texture storage format alone
(a texture format such as A3I5/A5I3 describes storage capability, not the
alpha distribution of a particular decoded texture, and DECAL ignores texture
alpha for final alpha entirely):

| condition | class |
| --- | --- |
| `polygonAlpha == 0` | `wireframe` |
| `polygonAlpha < 31` | `translucent` |
| `polygonMode == decal` (final alpha is polygon alpha, texture alpha irrelevant) | `opaque` |
| MODULATE, texture alpha usage has both partial and fully-opaque texels | `mixed` |
| MODULATE, texture alpha usage has partial but no fully-opaque texels | `translucent` |
| MODULATE, texture alpha usage has a zero texel (no partial) | `cutout` |
| otherwise | `opaque` |

A `mixed` batch draws through both the opaque and translucent subpasses (see
"Shared full-resolution rasters" below): each fragment's own exact final alpha5 decides
which subpass's write, if any, survives at that fragment.

The RGB fragment combiner is the DS integer-domain equation (GBATEK's
MODULATE/DECAL blending modes, transcribed in `map.glsl`'s
`modulateRgb6`/`decalRgb6`), not floating-point multiplication. Both the
texture sample and the vertex color enter as 5-bit (0-31) components,
widened to the combiner's 6-bit (0-63) domain by melonDS's RGB555 expansion
(`expand5to6`: 0 stays 0, any non-zero `n` becomes `2n+1`). MODULATE is
`floor(((texture6+1)*(vertex6+1)-1)/64)` per channel. DECAL keeps the
polygon alpha as output alpha and blends RGB by the texel's own alpha:
texture alpha 0 keeps the vertex color, 31 keeps the texture color,
otherwise the two interpolate as
`floor((texture6*textureAlpha5 + vertex6*(31-textureAlpha5))/32)`. An
untextured polygon samples `vec4(1.0)`, which quantizes to (63,63,63,31) --
the identity element of both equations, so no separate synthetic-texture
uniform exists.

The shader composes 5-bit alpha as:

```text
Aout5 = floor((((At5 + 1) * (Ap5 + 1)) - 1) / 32)
```

For decal mode the resulting alpha is the polygon alpha. Cutout draws discard
when the final 5-bit alpha is zero, implemented as `alpha < 0.5 / 255`.

## Render passes

`RenderQueue` partitions draws into opaque / cutout / mixedOpaque / wireframe
(each an array of original items, submission order preserved) plus one joint
`blended` list of decorated pass records (`{item, fragmentPass, viewZ,
position}`, never a field stamped onto the original item). `blended` holds
both ordinary translucent items and a mixed item's translucent subpass,
sorted together back-to-front in view space (submission position breaks
ties) and honoring the polygon bit-11 translucent depth-write flag. The pass
order is filled world MRT geometry, selected translucency, then one edge-only
wireframe pass. `FieldState` supplies
ordered arrays of map geometry, buildings, neighbour-ring draws, and actors.
`RenderQueue` traverses those
parts with one monotonically increasing submission position, so cross-part
tie ordering is established without flattening or stamping the draw items.
`MapRenderer` owns and reuses the queue scratch arrays, and builds the queue
exactly once per frame for the MRT and translucent stages to share (see
"World raster targets and passes" above).

## Edge marking

HGSS field rendering enables DS edge marking with two real per-area color
tables (`romdump.src.digest.HgssFieldEdgeColors.TABLE_A`/`TABLE_B`, each eight
RGB555 entries), selected by `AreaData.lightTypeRaw`: zero selects table A,
non-zero selects table B. `MapAssetCompiler` resolves the table once per area
into `scene.edgeColors`, a required scene field (not a `MapRenderer`
constructor invariant); the renderer caches the table by reference and only
resends `u_edgeColors` when the active scene's table changes. Because edge
color composites directly into the six-bit scene RGB, `MapRenderer` decodes
each RGB555 entry with the same `expand5to6` rule as the fragment combiner
(`decodeRgb555ToRgb6Normalized`, normalized by 63) before sending it, not the
raw `/31` RGB555 float used for material/light registers.

The edge predicate is the DS rule, not a linear-eye-space heuristic: a pixel
is an edge when an orthogonal neighbor's polygon ID differs from the
center's AND the center is strictly in front of that neighbor
(`edge.glsl`'s `marked` test, table-indexed by `centerPolygonId >> 3`). The
compared depth is the DS 24-bit Z-buffer domain, derived from the same
value the shader also stores (see "Render-state depth" below); there is no
`DEPTH_STEP_TOLERANCE` fudge factor. An edge pixel's output is hardware-style
RGB replacement (`vec4(edgeColor, scene.a)`), never an alpha-mix with the
scene color, and there is no separate edge-opacity uniform.

The opaque polygon ID, the DS-quantized depth, the per-polygon fog gate, and
the last translucent ID are carried as separate channels of one `rgba32f`
attachment (`renderState`: R = opaque polygon ID / 63, G = DS Z depth as an
integer-valued float, B = fog gate 0 or 1, A = last translucent ID encoding --
0 means none, `(id + 1) / 64` means ID 0..63). The `1/64` steps are exactly
representable in binary floating point, so the A encoding is exact. The
clear/rear-plane state is `{63/63, 0xFFFFFF, 0, 0}`. Opaque, cutout,
mixed-opaque, and wireframe fragments write their own real 0..63 polygon ID
into R and reset A to 0, because the new top opaque pixel has no accepted
translucent overlay yet; there is no invented sentinel value. Ordinary
translucent state is maintained by the programmable compositor below, not by
the state pass.

## World raster targets and passes

Color and DS render state (polygon ID, quantized depth, and fog gate) share one
geometry pass over one bounded world-raster domain. The world raster is
independent of host presentation resolution:

* **`sceneColor` + `renderState` + `colorDepth`** (`map.glsl` in `WORLD_MRT`
  mode): the world raster. Production
  uses `WindowConfig.WORLD_3D_RASTER_SCALE = 2`, capping its height at 384
  DS-relative pixels while preserving the viewport aspect. The resolved world
  is nearest-upscaled once into the presentation viewport. Opaque, cutout, and
  mixed-opaque fragments write color to target 0 and render state to target 1
  atomically, controlled by one depth attachment. Wireframe edges are drawn
  afterward against the active MRT pair with real wireframe rasterization.
* **Color-only `map.glsl` variant**: translucent source-color rasterization
  and presentation sprites use the same combiner and lighting source without
  declaring a second output, so these paths can target a single color canvas.

The render queue is built once per frame. State-writing world geometry is
submitted once through the MRT shader; translucent color and metadata remain
separate because their compositor needs read-modify-write state semantics.
There is no dedicated state shader or state depth canvas.

### Render-state depth

The field camera selects DS Z buffering: `Camera_ApplyPerspectiveType`
(pokeheartgold `src/camera.c`) sets `gG3dDepthBufferingMode =
GX_BUFFERMODE_Z` for both the perspective and orthographic field cameras, and
`fieldmap.c` passes that mode to the buffer swap (`RequestSwap3DBuffers`/
`G3_SwapBuffers`), so melonDS follows the non-W branch of
`GPU3D::SubmitPolygon` for HGSS field polygons. The render state's green
channel is therefore the DS Z-buffer conversion of the host fragment's
normalized window depth (`map.glsl`'s `dsZbufferDepth`, evaluated from
`gl_FragCoord.z` in `[0,1]`):

```text
ndcZ   = 2 * windowZ - 1
ndc14  = trunc_toward_zero(ndcZ * 0x4000)
dsZ    = clamp((ndc14 + 0x3FFF) * 0x200, 0, 0xFFFFFF)
```

GLSL's float-to-int conversion truncates toward zero, matching the signed
quotient behavior of the formula's NDC scale. The clear/rear plane remains
the 24-bit maximum `0xFFFFFF` even though a geometry fragment at
`windowZ == 1` maps to `0xFFFE00` under the formula (see "Edge marking"
above); edge marking and fog consume these integer-valued G-channel depths
directly, with no camera-far rescaling. This depth-domain conversion is
exact per the pinned melonDS formula, but projection, rasterization, and
interpolation remain host-side -- this is not bit-exact DS rasterization (see
"Exact versus approximate behavior" below).

`FieldState` partitions only its actor list: `billboardProjection == true` items
are presentation sprites, while actor static models remain world items. Map,
building, neighbour, and map/building billboard items always remain world
geometry. `MapRenderer:draw` resolves the world first, then draws sprites
directly to the host at native presentation resolution. Their camera NDC is
affinely mapped into `worldViewport`, so pillarbox and letterbox bars remain
world-only; the unscaled camera UV still drives world-state lookup and rejects
fragments outside the world coverage. The stream is deliberately limited to
ordered opaque/cutout billboards and writes host depth for sprite-versus-sprite
occlusion. Sprite fragments compare their DS-quantized depth with the
low-resolution world state, use the same fog density endpoint sequence as the
world, and intentionally skip world edge marking; actor atlases remain nearest.

The world renderer selects projection identically for ordinary and billboard
world items (`item.billboardProjection and billboardProjection or
worldProjection`). It draws opaque, cutout, and mixed-opaque items through the
MRT shader, applies the selected translucency mode, then draws each wireframe
item once as an edge-only pass on the resulting active pair.

Target generations are allocated transactionally by one
`MapRenderer:_ensureTargets` call. The MRT color/state/depth set is always
staged; exact mode additionally stages one spare color/state pair and source
fragment color/meta buffers before anything published is touched. A failed
allocation releases only the staged canvases and leaves the previous complete
generation and its dimensions untouched. Final-resolve state uniforms are sent
when the active pair is known, not during target construction.

### Mixed final-alpha materials

A MODULATE material at polygon alpha 31 whose texture mixes fully opaque,
fully transparent, and partially transparent texels (`AlphaClassifier.MIXED`)
cannot be described as wholly opaque or wholly translucent by texture format
alone -- texture storage format (e.g. A3I5/A5I3) describes capability, not the
alpha distribution of a particular decoded texture, and DECAL ignores texture
alpha for final alpha entirely. Such a material draws once in the MRT pass as
`mixedOpaque`, then again only for its partial fragments in the joint `blended`
list via the selected translucency mode: each fragment's own exact final alpha5 (not a
float-epsilon comparison) decides which pass's write, if
any, survives -- alpha 0 discards everywhere, alpha 31 is opaque in both
  color and state, and alpha 1-30 blends through the selected translucency mode in color and
contributes translucent state, not opaque state.

### Translucency modes

The renderer defaults to `MapRenderer.TRANSLUCENCY_APPROXIMATE`. It draws the
sorted `blended` entries directly into the world color target with fixed-function
alpha blending, so translucent geometry adds geometry submissions but no
per-entry full-screen work. Approximate mode intentionally does not reproduce
same-ID rejection, integer RGB6/alpha5 destination blending, maximum destination
alpha, fog-gate AND, or last-translucent-ID state; this is the deliberate
low-end production tradeoff.

`MapRenderer.TRANSLUCENCY_EXACT` remains a normal supported construction mode for
a future graphics-quality selector. It retains the programmable compositor and
its exact same-ID, integer blend, maximum-alpha, fog-gate, and last-ID semantics.
Exact mode is higher cost: it performs one source raster and one full-screen
composite per blended entry. Exact-only shaders, spare canvases, and source
buffers are allocated only in exact mode. The source metadata buffer is `rgba8`
and encodes IDs as `(id + 1) / 64`; no source-color clear or initial destination
seed blits are required because invalid-source pixels copy the active destination.
This exactness applies to world-raster blending and state only. Native
presentation actors are composed after the world has resolved, so they do not
participate in exact translucent ordering with world polygons.

### Programmable translucent compositor

Fixed-function host alpha blending cannot reproduce DS translucent semantics:
a translucent fragment must read per-pixel state (the last translucent ID for
same-ID rejection), blend with exact integer DS RGB6/alpha5 arithmetic
(including `max` destination alpha), and mutate state (fog-gate `AND` and last
translucent ID). The compositor is a ping-pong read-modify-write:

* The published world-raster color/state pair and one spare world-raster color/state pair
  (`rgba32f` for state and the 24-bit depth) alternate as active and inactive
  destinations, plus the shared `colorDepth` attachment and two temporary
  source-fragment buffers (color `rgba8` and metadata `rgba8` carrying the
  valid flag, fog flag, and source polygon ID).
* For each `RenderQueue.blended` entry in its existing deterministic order,
  the renderer rasterizes only that item's accepted translucent or
  mixed-translucent fragments into the source buffers. Both source passes
  depth-test against the opaque pass's shared `colorDepth`; both source passes
  use `less` with depth writes disabled. The supported field contract rejects
  `translucentDepthWrite=true` at asset validation, so translucent source never
  mutates host depth.
* A full-screen composite shader then applies the exact integer blend/state
  equations only where source valid is true (otherwise copying the destination
  unchanged) into the inactive pair, then the pairs swap.
* After the loop, wireframe color drawing binds the active color with the
  shared `colorDepth` attachment; the active state is not a second color
  target. The final resolve then samples the same active pair, so final color
  and state remain aligned. No pass samples and writes the same target in one
  draw (no feedback hazard). The composite and the source rasterization both
  use `replace` semantics -- the composite does not
  apply a second host alpha blend to already-computed output, and ordinary
  translucent/mixed-translucent entries share this same compositor path.

Exact `GX_SORTMODE_AUTO` polygon ordering remains approximate: the compositor
preserves the current deterministic `RenderQueue.blended` back-to-front order
and does not implement the hardware's automatic translucent sort.

### Final resolve

`edge.glsl` samples `sceneColor` (its full-resolution `tex` input) and
`renderState` (a same-resolution sampler) together: because the two rasters
share one-to-one screen coverage, every fragment's state sample snaps/clamps
to the render-state pixel center via an explicit `statePixelCenter` -- never
texture-clamp behavior -- and an out-of-bounds neighbour probe returns the
same rear-plane state (`MapRenderer.DS_STATE_CLEAR`) a real off-screen sample
would. The four orthogonal neighbour probes (never diagonals) sit at a
distance of one integer edge radius, `u_edgeRadiusPx`, which `MapRenderer`
derives each frame from the field logical pixel scale
(`FieldViewport:logicalPixelScale(camera.zoom)` =
`(referenceFrame.height / 192) * zoom`, rounded to the nearest integer,
minimum 1) -- so DS-relative edge width is a sampling distance over the
full-resolution state, not a block of host pixels owned by one coarse state
texel. Ordering is strictly: scene RGB -> edge detection -> fog each candidate
(scene candidate `S -> Sf` and, when marked, edge candidate
`E = {edgeRGB, S.alpha} -> Ef` using the center state's single depth and fog
gate with the existing integer RGB6/alpha5 fog arithmetic) -> current
antialias approximation when marked (`u_antialiasEnabled`: `mix(Sf, Ef, 0.5)`
when true, matching the project's current 50% approximation, or `Ef` when
false). No-edge pixels receive `Sf`. Fog alpha is resolved before the mix.
Both candidates share the center state -- a single depth/fog state limitation
versus a future exact path that would fog distinct top and lower buffers
before coverage. The approximation does not claim exact DS lower-pixel
coverage -- output.

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
* Final-alpha-aware classification (opaque/cutout/translucent/mixed), never
  texture storage format alone (see "Alpha classification and fragment
  contract" above).
* Culling from polygon bits 6-7.
* Translucent bit-11 depth writes.
* MODULATE/DECAL fragment combiner in the DS integer domain, not floating
  multiplication (see "Alpha classification and fragment contract" above).
* The real HGSS field edge-color tables, per-area table selection, the
  strict DS edge predicate/depth representation, RGB-replacement edge
  compositing, the clear/rear-plane polygon ID (63, HGSS's real value, not an
  invented sentinel), and the opaque-ID/depth/fog-gate `renderState` attribute
  split, rasterized at the same full resolution as the color raster (see
  "Edge marking" and "Shared full-resolution rasters" above).
* HGSS field 3D anti-aliasing's current 50% edge-coverage approximation
  (half of each fogged candidate at a marked edge -- the project's approximation,
  not exact DS lower-pixel coverage -- see "Final resolve" above).
* Sampler wrap normalization (clamp, repeat, and mirrored repeat via
  `TEXIMAGE_PARAM` flip bits, mapped to LÖVE's `mirroredrepeat` wrap mode)
  and nearest-neighbor texture/presentation filtering, matching the DS's own
  point-sampled, unfiltered raster.
* Global DS fog: the two-gate (`DISP3DCNT` + per-polygon `FOG_ENABLE`) rule,
  melonDS's exact slope-aware density-table interpolation (endpoint
  duplication, the `>>2`/shift/`>>17` sequencing, the 127->128 saturation),
  and the post-combiner RGB and alpha blend (`/128`, not `/127`), applied in
  the final full-screen pass (`edge.glsl`, per candidate before the current
  50% approximation) from the
  DS Z-buffer depth the edge predicate also reads. The per-map/weather
  source of the fog color/table/offset/slope/alpha is real: `HgssFieldFog`
  resolves each map's HGSS `weatherId` (0-13) to the exact steady-state
  overlay-01 preset (`ov01_021EC94C`/`ov01_021ECD08`/`ov01_021ED0F0`/
  `ov01_021ED584`/`ov01_021ED710`/`ov01_021ED924`/`ov01_021EDA50`), and
  `MapAssetCompiler` compiles the resolved `enabled`/`color`/`offset`/`slope`/
  `alpha`/`table` subset onto every scene (`scene.weatherId`/`scene.fog`)
  unconditionally -- disabled weathers (Sunny/Sandstorm) carry a real
  disabled preset, not an invented one. Every real preset uses fog blend
  mode 0 (color+alpha); mode 1 (alpha-only) never occurs in this table.
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
* Scene / G4M2 / cache explicit versioning and invalidation (see "Cache
  invalidation" below for the current version identities).

### Implemented exactly

* Exact-mode same-ID translucent self-blend rejection, exact integer RGB6/alpha5 blend
  with `w = srcAlpha5 + 1` and `max` destination alpha, fog-gate `AND`, and
  last-translucent-ID state via the programmable ping-pong compositor
  (see above). Approximate mode intentionally uses host fixed-function alpha
  blending and omits those exact state semantics; mixed-alpha partial texels
  use the selected mode.
* Exact DS vertex lighting, MODULATE/DECAL combiner, render-state depth,
  fog density, and the compositor's state contract described above.

### Deferred / approximate

These are documented rather than silently approximated. If a target map needs
one, the compiler raises a structured error instead of rendering incorrectly.

* Exact DS antialias lower-pixel coverage: the final pass keeps the project's
  current 50% approximation (half of each fogged candidate, both sharing the
  center depth/fog state) rather than generating exact DS edge coverage from a
  lower-pixel buffer. Future work can add a lower-pixel state buffer and fog
  its candidates independently before coverage.
* Exact DS automatic translucent Y sorting: HGSS field content is confirmed
  (via decomp) to genuinely use `GX_SORTMODE_AUTO`, but the exact hardware
  vertex-selection rule was never independently confirmed against melonDS, so
  the renderer keeps the pre-existing approximate object-center-Z
  back-to-front sort rather than tuning an unconfirmed rule. The programmable
  compositor preserves this current-project ordering and does not claim
  hardware-exact automatic sort.
* Runtime weather-ID overrides: HGSS rewrites the map's base `weatherId`
  before resolving fog in four ordered cases, implemented here via the
  generated `g4-field-weather-v1` catalog (`data/generated/field/weather/catalog.lua`,
  `FieldWeatherCache` / `DerivedAssetContract.fieldWeather`):

  1. Mt. Silver Cave Summit (map 465) on one of eight Diamond Dust dates
     (Jan 1, Jan 31, Feb 1, Feb 29, Mar 15, Oct 10, Dec 3, Dec 31) with
     `hasPenalty == false` becomes weather 8;
  2. Lake of Rage (map 88) when event variable `0x4037 == 0xF229` becomes
     weather 0;
  3. when the current weather is 9 and `FLAG_SYS_DEFOG` (2420) is set,
     becomes weather 0;
  4. when the current weather is 11 and `FLAG_SYS_FLASH` (2419) is set,
     becomes weather 12.

  The resolver (`FieldWeatherResolver`) folds the catalog's `rules` array in
  serialized order, applying each rule to the current weather (later rules
  consume earlier rewrites, not the base independently). The effective
  weather is computed once per map activation (fresh boot, resume, prepared
  and committed warp destination) via an injected `weatherClock: { today(),
  hasPenalty() }` sampled per activation, not per frame/draw/tick; the
  production default reads the host local calendar and reports no RTC penalty
  (broader anti-clock penalty detection is deferred). The selected fog is
  `scene.fog` when the effective ID equals the base, otherwise the catalog
  preset for the effective ID; `scene` remains `g4-map-scene-v7`. Weather
  particles and screen effects (rain, snow, diamond-dust particles,
  blizzard, sandstorm) are not implemented — only effective-weather
  selection and fog state.
* Fog's depth *input*: the final pass's density interpolation itself is exact
  melonDS sequencing (offset subtraction, the preset's own slope applied as
  the density shift exponent, `>>17` interval/fraction math, endpoint
  duplication, 127->128 saturation) -- there is no more fixed 32-way split,
  and the depth fed into that interpolation is the state G channel's DS
  Z-buffer value (see "Render-state depth" above), consumed directly with no
  camera-far rescaling. What remains approximate is the depth's *production*,
  not its domain: the host projects, rasterizes, and interpolates in float,
  and the DS Z conversion is applied to the host fragment's window depth --
  it is not bit-exact DS fixed-point clipping and subpixel rasterization, so
  absolute fog boundaries (how far away fog visibly starts/reaches full
  density) can still differ from the DS by a rounding step even though the
  depth-domain conversion itself is exact and the interpolation math applied
  to it is.
* `depthEqual` and `translucentDepthWrite`: never exercised anywhere in the
  target field corpus. `PolygonState.validate` rejects both true values with
  dedicated unsupported-state errors rather than approximating them with host
  depth behavior. The compositor preserves state G and updates only fog gate B
  and last-translucent-ID A.
* Shadow polygons and the `toon`/`highlight` polygon modes: absent from the
  full HeartGold field corpus census (every material resolves to
  `modulation`); compilation fails with `MAP_COMPILE_UNSUPPORTED_POLYGON_MODE`
  rather than silently approximating one if a future dump introduces it.
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
