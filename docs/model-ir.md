# Model IR — the engine-native model contract

This page defines the source-neutral model representation introduced by the
animation sprint: `ModelDefinition` /
`ModelInstance` and the pose backends, all in `libs/engine/src`. Vanilla
NSBMD/NSBCA assets and future Blender/GLB assets both land here; gameplay and
the renderer only ever see this shape.

The Lua faces of the contract are:

| Module | Role |
| --- | --- |
| `libs/engine/src/ModelDefinition.lua` | immutable model IR (nodes, meshes, materials, skins, animations) + validation + semantic clip resolution |
| `libs/engine/src/AnimationClip.lua` | normalized animation clip contract |
| `libs/engine/src/ModelInstance.lua` | per-model runtime (transform, animation state, material state, pose, draw items) |
| `libs/engine/src/PoseBackend.lua` | pose backend registry and contract |
| `libs/engine/src/GenericPoseBackend.lua` | TRS hierarchy evaluator (non-Nitro models) |
| `libs/engine/src/NitroPoseBackend.lua` | Nitro pose evaluator: compiled transform program + compiled clips |
| `libs/engine/src/NsbmdSbcEvaluator.lua` | pose-driven SBC replay (shared by digest tests and the runtime) |
| `libs/engine/src/NsbmdJointTransforms.lua` | Nitro scaling-rule joint composition (standard/Maya), shared by both pose paths |
| `libs/engine/src/CompiledNsbcaSampler.lua`, `libs/engine/src/NitroJointState.lua` | runtime sampling of compiled NSBCA clips and result-to-SRT composition |
| `libs/assets/src/MeshWriter.lua`, `libs/engine/src/SceneMesh.lua` | mesh serialization (G4M2 static, G4M3 animation-capable) |

The rule that shapes everything here:

> Vanilla and mod assets share the runtime abstraction, not the source format.
> A Blender asset must never become an NSBMD/NSBCA to work in the engine.

## Coordinate contract

The engine-native model space is fixed and documented so mod authors never
apply undocumented corrections:

- **Right-handed, Y-up**, one engine unit = one field tile (matching the
  runtime field grid; see `romdump/src/digest/MapUnits.lua` for the Nitro
  side of the same calibration).
- **Origin at the model placement point; the ground plane passes through the
  local origin** (Y = 0 is the floor at placement).
- All axis, handedness, and scale conversion between a source format and
  engine space is an **import-time** concern. The importer (Nitro compiler
  today, glTF importer in the future) performs every conversion; the runtime
  and gameplay never do.
- Rotation representation is a 9-cell orthonormal matrix everywhere in the
  IR. A glTF importer converts quaternion keys to matrices at import time and
  converts the glTF node convention (`T * R * S`, column-major) without
  exposing either to the runtime. This is the same rotation representation
  the Nitro path uses, so both pose backends blend orientations identically.

## Nodes and transforms

- `nodes` is a flat list, zero-based and contiguous, in
  **parent-before-child order** (a node's parent always has a smaller index).
  This makes pose evaluation a single top-down pass with no re-sorting.
- Each node carries a local `translation` (`{x,y,z}`), `rotation` (9-cell),
  and `scale` (`{x,y,z}`). The generic backend composes
  `local = T * R * S` (the glTF convention).
- Linear rotation interpolation between 9-cell keys lerps the cells and then
  rebuilds the matrix with the engine's basis-vector orthonormalization
  (row 2 = cross(row 0, row 1), rows normalized) — the same contract the
  joint blend uses. `step` keys are author-provided rotations.

## Meshes and the G4M3 vertex format

Two serialized mesh formats exist (`libs/assets/src/MeshWriter.lua`):

- **G4M2** — the legacy baked layout (40-byte stride): position, UV, normal,
  color, color-source. Unchanged; static map/building geometry keeps it.
- **G4M3** — the animation-capable layout (48-byte stride): G4M2 plus four
  joint indices (`u8`) and four joint weights (`u8`, 255 = 1.0). A skinned
  vertex's weights sum to exactly 255; a rigid vertex carries zero weights
  with zero joint indices.

G4M3 geometry can express up to four joint influences per vertex — the
generic/modding contract. Nitro geometry is not required to use them. The
renderer's base vertex layout (`libs/assets/src/VertexFormat.lua`) is
unchanged: joints/weights are pose-time data read by the skinning path, not
upload attributes.

## Skins

A skin is a list of joint node indices plus an inverse bind matrix per joint:

```
skinMatrix[joint] = globalTransform(joint) x inverseBindMatrix(joint)
```

`GlobalTransform` is the node's world matrix in model space, produced by the
pose backend. This is the glTF convention; the `GenericPoseBackend` computes
palettes into `PoseState.jointPalettes`. The future glTF importer maps
`skin.joints` and `inverseBindMatrices` 1:1 onto this contract.

## Material contract

A definition material is deliberately small — the `hgss_field` import
profile's output and the baseline every richer profile must map onto:

| Field | Meaning | Renderer mapping (`ModelInstance:effectiveMaterial`) |
| --- | --- | --- |
| `baseColor` | `{ r, g, b, a }` in 0..255 | diffuse/tint + alpha base |
| `alphaMode` | `"opaque" | "mask" | "blend"` | render class: opaque / cutout / translucent (the RenderQueue passes) |
| `doubleSided` | boolean | culling: `"none"` when true, else `"back"` |
| `texture` | image reference or nil | bound as the material's texture |

The base color factor / alpha mode of a glTF material map onto these fields;
unsupported PBR features become warnings at import, never silent rendering
differences. Per-instance overrides (alpha, later NSBMA colors and NSBTP
texture variants) live in `ModelInstance.materialState` and never mutate the
shared definition.

Animated (Nitro) materials add the fields the material evaluator needs:

| Field | Meaning |
| --- | --- |
| `polygonAlpha` | the polygon's 5-bit alpha (0..31); NSBMA animates it |
| `texMtxMode` | the model's texture-matrix convention (0 Maya, 1 Si3D, 2 3ds Max, 3 XSI); only Maya and Si3D have compiled formulas |
| `texWidth` / `texHeight` | the base texture's dimensions (the mesh UVs were normalized against them; the runtime reconstructs texel space) |
| `textureFormat`, `alphaUsage` | the base texture's raw NSBTX format and decoded alpha usage, for the per-frame render classification |
| `srt` / `srtMatrix` | the static texture-SRT state (or precomputed 4x4) from the material's SRT extension, in the compiled shape the evaluator consumes |
| `variants` | the NSBTP texture/palette variants the model's pattern clips can select: `{ name, texture, width, height, textureFormat, alphaUsage }`, keyed `texName[+paletteName]` |

The effective per-frame material state (`MaterialEvaluator`) composes, in
order: base material → NSBMA colors/alpha → NSBTA texture transform (the
convention's six 1.3.12 cells composed into a normalized-UV 3x3 against the
current texture's dimensions) → NSBTP texture selection → render
classification via `AlphaClassifier` before the RenderQueue is built.
Static materials keep the precomputed classification.

## Animations and semantic names

Clips are `AnimationClip` values: `id`, `name`, `category`
(`joint`/`material`/`visibility`), `kind`, `frameCount`, `tracks`, optional
`semanticNames`, and an opaque `source` provenance block. Joint tracks carry
the channels `translation`, `rotation`, and `scale` (keys `{ frame, value }`,
interpolation `step` or `linear`); visibility tracks carry `visible`
(boolean keys, `step`). Material channel shapes are defined by their
consumers. Gameplay never addresses clips by Nitro resource index or
animation-list slot — it uses semantic roles:

```lua
instance:play("door.open")   -- resolves via clip semanticNames
instance:stop("door.open")
```

A vanilla asset maps `door.open` to a compiled NSBCA clip; a mod asset maps
it to a glTF animation named `DoorOpen`. Gameplay cannot tell the difference.

## Pose backends

`PoseBackend.evaluate(instance)` dispatches on `ModelDefinition.sourceBackend`
and returns a `PoseState`:

```
PoseState = {
  nodeMatrices   -- [nodeIndex] = column-major world matrix (model space)
  nodeVisible    -- [nodeIndex] = false when hidden; absent = visible
  jointPalettes  -- [skinId][joint] = skinMatrix (world x inverseBind)
}
```

The generic backend walks the TRS hierarchy and overlays joint/visibility
clips. The Nitro backend replays the compiled SBC transform program over the
animated joint results; evaluating a nitro-backed instance with
joint/visibility attachments raises a structured diagnostic only when the
definition lacks the program (no silent fallback). The two backends may use
completely different internal algorithms; only the final `PoseState` is
shared.

## The Nitro dynamic path

A nitro-backed definition's `backend` payload carries two pieces produced by
the digest:

- **`program`** — the compiled transform program (NsbmdTransformProgram):
  the decoded SBC command stream, the node bind SRTs, the scaling rule,
  POSSCALE factors, the inverse-bind block, and `tileScale` (the model-to-
  engine-unit conversion for runtime matrices, `1 / MODEL_UNITS_PER_TILE`).
  `NsbmdSbcEvaluator` replays it with a pose provider; the bind-pose
  provider is exactly the static compilation `NsbmdStaticTransforms`
  returns, and the invariant is checked in
  `romdump/tests/nsbmd_dynamic_mesh_test.lua` (static batches vs dynamic
  meshes resolved at the bind pose).
- **`meshes`** — per-mesh transform sources: `{ drawIndex,
  positionSource, transformMode }`. Geometry ships in
  pre-draw space (transform-preserving compile); a source is
  `"draw"` (the SBC draw's matrix) or `{ slot = k }` (matrix-stack slot k as
  of that draw). Billboard segments are fully baked and carry no source.
  Display-list-local matrix ops bake into the vertices except MTX_RESTORE,
  which splits a segment onto a slot source (GxDisplayList `options.dynamic`).

Pose evaluation per frame: compiled clips (NsbcaClipCompiler) sample through
CompiledNsbcaSampler — bit-identical to the raw decoders, cross-checked in
`romdump/tests/nsbca_clip_compiler_test.lua` — blend per node through
JointAnimBlend, compose via NitroJointState, and feed the evaluator. The
result extends `PoseState` with `drawMatrices`:

```
PoseState.drawMatrices = { [meshId] = {
  position,         -- tile-space matrix (engine units)
  direction,        -- the linear part (the supported op set keeps
                    -- direction == linear(position))
  transformMode,    -- "static" | "billboard"
  baseTransform,    -- billboard only: the pose-dependent captured matrix
} }
PoseState.matrixSlots = { [slot] = tile-space matrix }
```

`matrixSlots` is the matrix-stack slot state as of the end of the replay —
the "matrix slots" the animation debugging overlay visualizes alongside the
node transforms.

`ModelInstance.drawItems` prefers `drawMatrices` over the node-matrix path,
so a Nitro draw (which is not one node matrix) renders correctly. Geometry
is compiled once; only the matrices move.

## The animated material path

Material clips (NSBTA/NSBTP/NSBMA) compile through the matching
`Nsb*ClipCompiler` (digest) and sample through the matching
`CompiledNsb*Sampler` (engine), bit-identical to the raw decoders and
cross-checked in `romdump/tests/material_clip_compiler_test.lua`.
`ModelInstance:evaluateMaterials` runs `MaterialEvaluator` over the
definition materials and the material attachments; `effectiveMaterial` then
carries the resolved image, the normalized UV 3x3 (`u_texMatrix` in the map
shader), the per-component animated colors (`u_matDiffuse` etc.), the
effective polygon alpha, and the recomputed `alphaClass`. The render
classification always runs before the RenderQueue is built, so animated
materials migrate between opaque/cutout/translucent per frame. The renderer
resolves the texture image through the instance's `resolveImage` callback
(the scene loader passes the cache's image cache).

## The map-prop descriptor and controller

The digest writes an animated building as a dynamic model descriptor (the
cache form `ModelDefinition.fromNitroDescriptor` assembles):

```
{ key, memberId, backend = "nitro",
  dynamic = { nodes, transformProgram, batches },   -- the dynamic half
  materials,                                        -- base + variants
  animations,                                       -- compiled nitro clips
  roles }                                           -- semantic -> clip name
```

`MapSceneLoader` turns each placed instance of such a descriptor into a
`ModelInstance` (G4M3 render meshes built once, `resolveImage` wired to the
texture cache) and exposes `runtime.animatedInstances`,
`runtime.animationController` (a `MapPropAnimationController`), and the
per-frame hooks `runtime:updateAnimated()` (advanced by `FieldSession` each
tick) and `runtime:syncAnimatedDraws()` (called by `MapRenderer` before
drawing). A model with exactly one clip plays it looping from load — the
ambient props (wind, machines, springs); multi-clip models (doors) are
scripted through the controller by semantic role. `AnimationDebugger`
snapshots every attachment (frame, format, provenance, priority, ratio,
bound targets) for the inspector UI.

## glTF mapping contract

A future glTF importer maps:

```text
POSITION            -> G4 position
NORMAL              -> normal
TEXCOORD_0          -> primary UV
COLOR_0             -> vertex color
JOINTS_0            -> four joint indices
WEIGHTS_0           -> four joint weights (normalized to 0..255)

node hierarchy      -> ModelDefinition.nodes
translation/rotation/scale -> local node TRS (quaternion -> 9-cell)

skin joints         -> SkinDefinition.joints
inverseBindMatrices -> SkinDefinition.inverseBindMatrices

animation           -> AnimationClip
animation channel   -> node property track
animation name      -> clip name (semantic aliases assigned by gameplay
                       association, e.g. door.open -> "DoorOpen")
```

The runtime never requires fake Nitro metadata for generic models.
