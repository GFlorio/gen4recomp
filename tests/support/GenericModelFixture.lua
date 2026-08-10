-- GenericModelFixture: the synthetic, non-Nitro proof model used by the
-- animation runtime tests. It is a door-shaped rigid hierarchy with a
-- semantic rigid-node animation, a visibility clip, and a skinned mesh whose
-- vertices carry four joint influences -- nothing here originates from an
-- NSBMD or any Nitro format, exactly like a future Blender/GLB import.
--
-- Layout (1 unit = 1 field tile, Y-up, glTF convention):
--   node 0  "frame"    static root at the origin
--   node 1  "leaf"     child of node 0, hinged at the origin, animated rotY
--   node 2  "skinRoot" static root for the skinned mesh
--   node 3  "skinLeaf" child of node 2
--
-- Animations:
--   "DoorOpen"  (semantic door.open)   leaf rotY 0 -> DOOR_SWING_RAD over 8 frames
--   "DoorClose" (semantic door.close)  leaf rotY DOOR_SWING_RAD -> 0 over 8 frames
--   "blink"     (visibility)           leaf visible at frames 0-1 and 4+, not 2-3
--
-- doorDefinition() returns the ModelDefinition with the mesh batches wired
-- in (each mesh's `batch` is MeshWriter-shaped, the skinned one with G4M3
-- skin attributes). Test-only.

local ModelDefinition = require("libs.engine.src.ModelDefinition")
local AnimationClip = require("libs.engine.src.AnimationClip")

local GenericModelFixture = {}

-- Total swing of the door animation, radians about Y.
local DOOR_SWING_RAD = 1.5
-- Animation length in frames for every clip.
local FRAME_COUNT = 8

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

local function rotY(rad)
  local c, s = math.cos(rad), math.sin(rad)
  return { c, 0, -s, 0, 1, 0, s, 0, c }
end

local function jointClip(id, name, sematics, tracks)
  return AnimationClip.new({
    id = id,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = FRAME_COUNT,
    tracks = tracks,
    semanticNames = sematics,
    source = { type = "gltf", file = "fixture.glb", animation = name },
  })
end

-- A vertex with G4M3 skin attributes; without them it is a rigid vertex.
local function vertex(x, y, z, joints, weights)
  local v = {
    x = x,
    y = y,
    z = z,
    u = x,
    v = y,
    nx = 0,
    ny = 0,
    nz = -1,
    r = 255,
    g = 255,
    b = 255,
    a = 255,
    colorSource = 0,
  }
  if joints then
    v.joints, v.weights = joints, weights
  end
  return v
end

local function quad(joints, weights)
  return {
    vertices = {
      vertex(-1, 0, 0, joints, weights),
      vertex(1, 0, 0, joints, weights),
      vertex(1, 2, 0, joints, weights),
      vertex(-1, 2, 0, joints, weights),
    },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

local function doorBatches()
  return {
    frame = quad(nil, nil),
    leaf = quad(nil, nil),
    -- Two-influence skinned quad: four joint slots exercised, weights sum 255.
    skin = quad({ 2, 3, 0, 0 }, { 128, 127, 0, 0 }),
  }
end

function GenericModelFixture.doorDefinition()
  local batches = doorBatches()
  local open = jointClip("fixture:door.open", "DoorOpen", { "door.open" }, {
    {
      target = 1,
      channels = {
        rotation = {
          interpolation = "linear",
          keys = {
            { frame = 0, value = rotY(0) },
            { frame = FRAME_COUNT - 1, value = rotY(DOOR_SWING_RAD) },
          },
        },
      },
    },
  })
  local close = jointClip("fixture:door.close", "DoorClose", { "door.close" }, {
    {
      target = 1,
      channels = {
        rotation = {
          interpolation = "linear",
          keys = {
            { frame = 0, value = rotY(DOOR_SWING_RAD) },
            { frame = FRAME_COUNT - 1, value = rotY(0) },
          },
        },
      },
    },
  })
  local blink = AnimationClip.new({
    id = "fixture:blink",
    name = "blink",
    category = "visibility",
    kind = "visibility",
    frameCount = FRAME_COUNT,
    tracks = {
      {
        target = 1,
        channels = {
          visible = {
            interpolation = "step",
            keys = {
              { frame = 0, value = true },
              { frame = 2, value = false },
              { frame = 4, value = true },
            },
          },
        },
      },
    },
    source = { type = "gltf", file = "fixture.glb", animation = "blink" },
  })

  return ModelDefinition.new({
    key = "fixture:door",
    sourceBackend = "generic",
    nodes = {
      {
        index = 0,
        name = "frame",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 1,
        name = "leaf",
        parentIndex = 0,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 2,
        name = "skinRoot",
        translation = { x = 4, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 3,
        name = "skinLeaf",
        parentIndex = 2,
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      { id = "frame", name = "frame", nodeIndex = 0, materialIndex = 0, batch = batches.frame },
      { id = "leaf", name = "leaf", nodeIndex = 1, materialIndex = 0, batch = batches.leaf },
      { id = "skin", name = "skin", nodeIndex = 3, materialIndex = 1, batch = batches.skin },
    },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
      {
        id = 1,
        name = "glass",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "mask",
        doubleSided = true,
      },
    },
    skins = {
      {
        id = "skin",
        joints = { 2, 3 },
        inverseBindMatrices = {
          [2] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -4, 0, 0, 1 },
          [3] = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -4, 0, 0, 1 },
        },
      },
    },
    animations = { open, close, blink },
    instanceMetadata = { fixture = "generic-door" },
  })
end

return GenericModelFixture
