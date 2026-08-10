-- AnimationDebugOverlay: the data model behind the in-game animation
-- debugging overlays (spec section 39). It gathers a scene runtime's
-- animation observability -- AnimationDebugger snapshots per instance, node
-- transforms and Nitro matrix slots from the pose, pose-performance and
-- allocation counters, the time band, scene stats -- into one plain table
-- the overlay UI renders, and produces the world-space axis segments the
-- node-transform and matrix-slot visualizations draw. Pure domain module;
-- the love-gated view that renders the data lives in the game app.
--
-- The Nitro matrix-slot view reads PoseState.matrixSlots (the matrix-stack
-- slots as of the end of the SBC replay, in engine units); the node view
-- reads PoseState.nodeMatrices (model space, converted per backend). Both
-- compose the instance transform, so the axis segments are world-space and
-- line up with the rendered scene.

local Matrix4 = require("libs.math.src.Matrix4")
local AnimationDebugger = require("libs.engine.src.AnimationDebugger")

local AnimationDebugOverlay = {}

-- The measured phases of the pose pipeline, in display order.
local PHASES = { "pose", "material", "update", "bandSwap", "sync" }

local AXES = { "x", "y", "z" }

-- The basis column indices of a column-major matrix, per axis.
local AXIS_COLUMNS = {
  x = { 1, 2, 3 },
  y = { 5, 6, 7 },
  z = { 9, 10, 11 },
}

local function instanceLabel(instance)
  return instance.definition.key .. "#" .. tostring(instance.placementIndex or "?")
end

-- The compiled program of a Nitro definition (nil for generic models).
local function programOf(instance)
  local backend = instance.definition.backend
  return backend and backend.program or nil
end

-- The model-to-engine conversion factor of a definition: Nitro node
-- matrices live in model units (the program's tile scale converts them),
-- generic IR node matrices are already 1 unit = 1 tile.
local function tileScaleOf(instance)
  local program = programOf(instance)
  return program and program.tileScale or 1
end

-- Copy a Nitro model-space matrix into engine units: only the translation
-- column scales (the draw contract does the same in NitroPoseBackend).
local function toTiles(m, tileScale)
  if tileScale == 1 then
    return m
  end
  local out = {}
  for i = 1, 12 do
    out[i] = m[i]
  end
  out[13], out[14], out[15] = m[13] * tileScale, m[14] * tileScale, m[15] * tileScale
  out[16] = m[16]
  return out
end

-- ---- gathering ----

-- The node readout: every definition node with its pose matrix (translation
-- in engine units), visibility, and the matrix-stack slot it writes (Nitro
-- only). Without a pose the matrix and translation are absent.
local function nodeReadout(instance, pose)
  local definition = instance.definition
  local program = programOf(instance)
  local tileScale = tileScaleOf(instance)
  local out = {}
  for nodeIndex = 0, #definition.nodes - 1 do
    local node = definition.nodes[nodeIndex + 1]
    local matrix = pose and pose.nodeMatrices[nodeIndex]
    local entry = {
      index = nodeIndex,
      name = node.name,
      slot = program and program.nodes[nodeIndex + 1] and program.nodes[nodeIndex + 1].matrixStackIndex or nil,
      visible = not pose or pose.nodeVisible[nodeIndex] ~= false,
    }
    if matrix then
      local m = toTiles(matrix, tileScale)
      entry.matrix = m
      entry.translation = { m[13], m[14], m[15] }
    end
    out[#out + 1] = entry
  end
  return out
end

-- The matrix-slot readout: every populated matrix-stack slot of the pose,
-- in engine units, sorted by slot index.
local function slotReadout(pose)
  local out = {}
  if not (pose and pose.matrixSlots) then
    return out
  end
  for slot, m in pairs(pose.matrixSlots) do
    out[#out + 1] = {
      slot = slot,
      matrix = m,
      translation = { m[13], m[14], m[15] },
    }
  end
  table.sort(out, function(a, b)
    return a.slot < b.slot
  end)
  return out
end

-- The per-mesh draw readout: each dynamic mesh with its resolved matrix and
-- the transform source it resolves from ("draw" or "slot N").
local function drawReadout(instance, pose)
  local out = {}
  local meshRecords = instance.definition.backend and instance.definition.backend.meshes
  for meshId, draw in pairs(pose and pose.drawMatrices or {}) do
    local source = meshRecords and meshRecords[meshId] and meshRecords[meshId].positionSource
    out[#out + 1] = {
      meshId = meshId,
      source = type(source) == "table" and ("slot " .. tostring(source.slot)) or source or "-",
      transformMode = draw.transformMode,
      matrix = draw.position,
      translation = { draw.position[13], draw.position[14], draw.position[15] },
    }
  end
  table.sort(out, function(a, b)
    return a.meshId < b.meshId
  end)
  return out
end

-- The overlay data of one instance: the debugger snapshot, the node and
-- matrix-slot readouts, and the draw records.
function AnimationDebugOverlay.gatherInstance(instance)
  assert(type(instance) == "table" and instance.definition ~= nil, "gatherInstance requires a ModelInstance")
  local pose = instance.poseState
  return {
    label = instanceLabel(instance),
    modelKey = instance.definition.key,
    placementIndex = instance.placementIndex,
    backend = instance.definition.sourceBackend,
    animations = AnimationDebugger.snapshot(instance),
    nodes = nodeReadout(instance, pose),
    slots = slotReadout(pose),
    draws = drawReadout(instance, pose),
  }
end

-- The overlay data of a scene runtime (MapSceneLoader's runtime surface):
-- scene stats, the time band, the pose-performance rows and totals, the
-- allocation counters, and every animated instance's overlay data.
-- `rendererStats` (optional) carries the frame's draw-call count.
function AnimationDebugOverlay.gather(runtime, rendererStats)
  assert(type(runtime) == "table" and runtime.scene ~= nil, "gather requires a scene runtime")
  local perf = runtime.perf
  local perfRows = {}
  if perf then
    perfRows = perf:summary(function(key)
      if type(key) == "table" and key.definition and key.definition.key then
        return instanceLabel(key)
      end
      return tostring(key)
    end)
  end
  local perfTotals = {}
  for _, phase in ipairs(PHASES) do
    perfTotals[phase] = perf and perf:count(nil, phase) or 0
  end
  local instances = {}
  for _, instance in ipairs(runtime.animatedInstances or {}) do
    instances[#instances + 1] = AnimationDebugOverlay.gatherInstance(instance)
  end
  return {
    scene = {
      mapId = runtime.scene.mapId,
      mapSymbol = runtime.scene.mapSymbol,
      timeBand = runtime.timeBand,
      animatedInstances = #instances,
      animatedModelCount = runtime.stats and runtime.stats.animatedModelCount or 0,
      meshCount = runtime.stats and runtime.stats.meshCount or 0,
      textureCount = runtime.stats and runtime.stats.textureCount or 0,
      triangleCount = runtime.stats and runtime.stats.triangleCount or 0,
      drawCalls = rendererStats and rendererStats.drawCalls or 0,
    },
    perf = perfRows,
    perfTotals = perfTotals,
    alloc = runtime.alloc and runtime.alloc:report() or {},
    instances = instances,
  }
end

-- ---- world-space axis segments ----

-- Append the three axis segments of one matrix to `segments`: the origin is
-- the matrix translation (engine units), each axis points along the matrix's
-- basis column normalized to `length` (default 1 tile).
local function appendAxisSegments(segments, world, length)
  local origin = { world[13], world[14], world[15] }
  for _, axis in ipairs(AXES) do
    local i0, i1, i2 = AXIS_COLUMNS[axis][1], AXIS_COLUMNS[axis][2], AXIS_COLUMNS[axis][3]
    local d = math.sqrt(world[i0] * world[i0] + world[i1] * world[i1] + world[i2] * world[i2])
    local to = { origin[1], origin[2], origin[3] }
    if d > 0 then
      to[1] = to[1] + world[i0] / d * length
      to[2] = to[2] + world[i1] / d * length
      to[3] = to[3] + world[i2] / d * length
    end
    segments[#segments + 1] = {
      axis = axis,
      from = origin,
      to = to,
    }
  end
end

-- The world-space axis segments of every node matrix in the instance's pose
-- (the node-transform visualization). `opts.length` (default 1) is the axis
-- length in tiles. Empty before the first pose evaluation.
---@param instance table
---@param opts? { length?: number }
---@return { axis: string, from: number[], to: number[] }[]
function AnimationDebugOverlay.nodeAxisSegments(instance, opts)
  opts = opts or {}
  local length = opts.length or 1
  local segments = {}
  local pose = instance.poseState
  if not pose then
    return segments
  end
  local tileScale = tileScaleOf(instance)
  for nodeIndex = 0, #instance.definition.nodes - 1 do
    local matrix = pose.nodeMatrices[nodeIndex]
    if matrix then
      local world = Matrix4.multiply(instance.transform, toTiles(matrix, tileScale))
      appendAxisSegments(segments, world, length)
    end
  end
  return segments
end

-- The world-space axis segments of every populated matrix-stack slot in the
-- pose (the matrix-slot visualization), sorted by slot index. Empty for
-- generic models and before the first pose evaluation.
---@param instance table
---@param opts? { length?: number }
---@return { axis: string, from: number[], to: number[] }[]
function AnimationDebugOverlay.slotAxisSegments(instance, opts)
  opts = opts or {}
  local length = opts.length or 1
  local segments = {}
  local pose = instance.poseState
  if not (pose and pose.matrixSlots) then
    return segments
  end
  local slots = {}
  for slot in pairs(pose.matrixSlots) do
    slots[#slots + 1] = slot
  end
  table.sort(slots)
  for _, slot in ipairs(slots) do
    local world = Matrix4.multiply(instance.transform, pose.matrixSlots[slot])
    appendAxisSegments(segments, world, length)
  end
  return segments
end

return AnimationDebugOverlay
