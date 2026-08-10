-- Tests for AnimationDebugOverlay: the pure data model behind the in-game
-- animation debugging overlays (spec section 39). The gather functions read
-- a scene runtime into one plain table the overlay UI renders -- debugger
-- snapshots per instance, node transforms and Nitro matrix slots from the
-- pose, pose-performance and allocation counters, the time band -- and the
-- axis-segment functions produce the world-space lines the node-transform
-- and matrix-slot visualizations draw. Everything here is headless; the
-- love-gated view that renders the data lives in the game app.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local GenericModelFixture = require("tests.support.GenericModelFixture")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local PosePerformanceCounter = require("libs.engine.src.PosePerformanceCounter")
local RuntimeAllocationProfiler = require("libs.engine.src.RuntimeAllocationProfiler")
local AnimationDebugOverlay = require("libs.engine.src.AnimationDebugOverlay")

local T = {}

local EPS = 1e-6

local function assertClose(actual, expected, msg)
  for i = 1, #expected do
    if math.abs(actual[i] - expected[i]) > EPS then
      error(
        (msg or "vector mismatch")
          .. ": expected ("
          .. expected[1]
          .. ","
          .. expected[2]
          .. ","
          .. expected[3]
          .. "), got ("
          .. actual[1]
          .. ","
          .. actual[2]
          .. ","
          .. actual[3]
          .. ")"
      )
    end
  end
end

local function identity9()
  return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

-- ---- fixtures ----

local function genericInstance(opts)
  opts = opts or {}
  local instance = ModelInstance.new(GenericModelFixture.doorDefinition(), {
    transform = opts.transform,
    performance = opts.performance,
  })
  if opts.play then
    instance:play(opts.play)
  end
  if opts.advance then
    for _ = 1, opts.advance do
      instance:updateFixed()
    end
  end
  if opts.pose ~= false then
    instance:evaluatePose()
  end
  return instance
end

-- The two-node slot fixture shape of nitro_pose_backend_test: node 1's
-- matrix lives in matrix-stack slot 1; the draw restores it.
local function slotDefinition()
  local program = {
    name = "slot-test",
    scalingRule = 0,
    posScale = 1,
    invPosScale = 1,
    tileScale = 1 / 16,
    nodes = {
      {
        index = 0,
        matrixStackIndex = 0,
        translation = { x = 16, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = false,
        rotZero = false,
        scaleOne = false,
      },
      {
        index = 1,
        matrixStackIndex = 1,
        translation = { x = 0, y = 32, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
        transZero = false,
        rotZero = false,
        scaleOne = false,
      },
    },
    commands = {
      { opcode = 0x06, nodeIndex = 0, parentIndex = 0, flags = 0 },
      { opcode = 0x06, nodeIndex = 1, parentIndex = 1, flags = 0 },
      { opcode = 0x03, matrixSlot = 1 },
      { opcode = 0x04, materialIndex = 0 },
      { opcode = 0x05, shapeIndex = 0 },
      { opcode = 0x01 },
    },
    evpMatrices = nil,
  }
  return ModelDefinition.new({
    key = "fixture:nitro-slot",
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "a",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
      {
        index = 1,
        name = "b",
        translation = { x = 0, y = 0, z = 0 },
        rotation = identity9(),
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = {
      {
        id = "m",
        nodeIndex = 1,
        materialIndex = 0,
        batch = { vertices = { { x = 0, y = 0, z = 0 } }, indices = { 0, 0, 0 } },
      },
    },
    materials = {
      {
        id = 0,
        name = "mat0",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
      },
    },
    skins = {},
    animations = {},
    backend = {
      program = program,
      meshes = { m = { drawIndex = 0, positionSource = { slot = 1 }, transformMode = "static" } },
    },
  })
end

local function nitroInstance(opts)
  opts = opts or {}
  local instance = ModelInstance.new(slotDefinition(), { transform = opts.transform })
  if opts.pose ~= false then
    instance:evaluatePose()
  end
  return instance
end

-- A hand-built scene runtime in the MapSceneLoader surface shape.
local function runtimeWith(instances, perf, alloc)
  return {
    scene = { mapId = 61, mapSymbol = "MAP_NEW_BARK" },
    timeBand = "day",
    stats = {
      meshCount = 3,
      textureCount = 2,
      triangleCount = 12,
      animatedInstances = #instances,
      animatedModelCount = 1,
    },
    animatedInstances = instances,
    perf = perf,
    alloc = alloc,
  }
end

-- ---- gather: scene ----

function T.gather_reports_scene_stats_perf_and_alloc()
  local perf = PosePerformanceCounter.new()
  local a = genericInstance({ play = "DoorOpen", advance = 2, performance = perf })
  a.placementIndex = 3
  a:drawItems({ frame = {}, leaf = {}, skin = {} })
  local alloc = RuntimeAllocationProfiler.new()
  alloc:add("pose", 1)
  local data = AnimationDebugOverlay.gather(runtimeWith({ a }, perf, alloc))

  Assert.equal(data.scene.mapId, 61)
  Assert.equal(data.scene.mapSymbol, "MAP_NEW_BARK")
  Assert.equal(data.scene.timeBand, "day")
  Assert.equal(data.scene.animatedInstances, 1)
  Assert.equal(data.scene.animatedModelCount, 1)
  Assert.equal(data.scene.triangleCount, 12)

  -- Per-instance rows are named model key # placement.
  Assert.equal(#data.perf, 2, "pose + material rows")
  Assert.equal(data.perf[1].key, "fixture:door#3")
  Assert.equal(data.perf[1].count, 1)
  Assert.isTrue(data.perf[1].seconds >= 0)
  Assert.equal(data.perf[1].phase, "material")
  Assert.equal(data.perf[2].phase, "pose")
  Assert.equal(data.perfTotals.pose, 1)
  Assert.equal(data.perfTotals.material, 1)
  Assert.equal(data.perfTotals.sync, 0)

  Assert.equal(#data.alloc, 1)
  Assert.equal(data.alloc[1].site, "pose")
  Assert.equal(data.alloc[1].total, 1)
end

function T.gather_tolerates_a_static_scene_without_counters()
  local data = AnimationDebugOverlay.gather(runtimeWith({}, nil, nil))
  Assert.equal(#data.instances, 0)
  Assert.equal(#data.perf, 0)
  Assert.equal(#data.alloc, 0)
  Assert.equal(data.scene.animatedInstances, 0)
  Assert.isTrue(data.perfTotals.pose == 0)
end

-- ---- gather: instance ----

function T.gather_instance_reports_the_debugger_snapshot()
  local instance = genericInstance({ play = "DoorOpen", advance = 2 })
  local entry = AnimationDebugOverlay.gatherInstance(instance).animations[1]
  Assert.equal(instance.definition.key, "fixture:door")
  Assert.equal(entry.clipName, "DoorOpen")
  Assert.deepEqual(entry.roles, { "door.open" })
  Assert.equal(entry.format, "generic", "the glTF fixture has no source format")
  Assert.equal(entry.frame, 2)
  Assert.equal(entry.frameCount, 8)
  Assert.isTrue(entry.playing)
  Assert.equal(entry.deltaFx, 4096)
  Assert.equal(entry.priority, 0x7F)
  Assert.equal(entry.ratioFx, 0x1000)
  Assert.isTrue(entry.boundTargets >= 1, "the door clip binds its node")
end

function T.gather_instance_reports_node_transforms_from_the_pose()
  local instance = genericInstance({ play = "DoorOpen", advance = 2 })
  local nodes = AnimationDebugOverlay.gatherInstance(instance).nodes
  Assert.equal(#nodes, 4, "one entry per definition node")
  Assert.equal(nodes[1].name, "frame")
  Assert.equal(nodes[1].index, 0)
  Assert.equal(nodes[1].slot, nil, "generic models have no matrix-stack slots")
  Assert.isTrue(nodes[1].visible)
  assertClose(nodes[1].translation, { 0, 0, 0 })
  assertClose(nodes[3].translation, { 4, 0, 0 }, "skinRoot at (4,0,0)")

  -- The leaf node (index 1) rotated by the DoorOpen swing: its matrix's
  -- translation stays at the origin (hinged), its x basis leaves the world
  -- x axis.
  assertClose(nodes[2].translation, { 0, 0, 0 })
end

function T.gather_instance_reports_matrix_slots_and_draw_sources()
  local instance = nitroInstance()
  local data = AnimationDebugOverlay.gatherInstance(instance)

  -- Slot 1 holds node 1's matrix at (0,2,0) tiles; slot 0 node 0 at (1,0,0).
  Assert.equal(#data.slots, 2)
  Assert.equal(data.slots[1].slot, 0)
  assertClose(data.slots[1].translation, { 1, 0, 0 })
  Assert.equal(data.slots[2].slot, 1)
  assertClose(data.slots[2].translation, { 0, 2, 0 })

  -- The mesh resolves its matrix from slot 1.
  Assert.equal(#data.draws, 1)
  Assert.equal(data.draws[1].meshId, "m")
  Assert.equal(data.draws[1].source, "slot 1")
  Assert.equal(data.draws[1].transformMode, "static")
  assertClose(data.draws[1].translation, { 0, 2, 0 })
end

function T.gather_instance_without_a_pose_reports_visualizations_empty()
  local instance = genericInstance({ play = "DoorOpen", pose = false })
  local data = AnimationDebugOverlay.gatherInstance(instance)
  Assert.equal(#data.animations, 1, "the snapshot works before the first pose")
  Assert.equal(#data.nodes, 4)
  Assert.equal(data.nodes[1].translation, nil, "no matrix yet")
  Assert.equal(#data.slots, 0)
  Assert.equal(#data.draws, 0)
end

-- ---- axis segments ----

function T.node_axis_segments_compose_the_instance_transform()
  local instance = genericInstance({
    play = "DoorOpen",
    advance = 2,
    transform = Matrix4.translate(5, 0, 0),
  })
  local segments = AnimationDebugOverlay.nodeAxisSegments(instance)
  -- Three axes per node with a matrix: 4 nodes -> 12 segments.
  Assert.equal(#segments, 12)

  -- Node 0 (frame) at the model origin, lifted by the instance transform.
  local x, y, z = segments[1], segments[2], segments[3]
  assertClose(x.from, { 5, 0, 0 })
  assertClose(x.to, { 6, 0, 0 }, "x axis length 1 along world +x")
  assertClose(y.to, { 5, 1, 0 })
  assertClose(z.to, { 5, 0, 1 })
  Assert.equal(x.axis, "x")
  Assert.equal(y.axis, "y")
  Assert.equal(z.axis, "z")

  -- Node 2 (skinRoot) sits at (4,0,0) model units.
  local root = segments[7]
  assertClose(root.from, { 9, 0, 0 })
  Assert.equal(root.axis, "x")
end

function T.node_axis_segments_follow_the_animated_orientation()
  -- DoorOpen swings the leaf from rotY(0) to rotY(1.5) over 8 frames; at the
  -- last frame the x basis is (cos 1.5, 0, -sin 1.5).
  local instance = genericInstance({ play = "DoorOpen", advance = 7 })
  local segments = AnimationDebugOverlay.nodeAxisSegments(instance)
  local leaf = segments[4] -- node 1 x axis
  assertClose(leaf.from, { 0, 0, 0 })
  assertClose(leaf.to, { math.cos(1.5), 0, -math.sin(1.5) })
end

function T.node_axis_segments_scale_with_the_option()
  local instance = genericInstance({ pose = false })
  instance:evaluatePose()
  local segments = AnimationDebugOverlay.nodeAxisSegments(instance, { length = 2 })
  assertClose(segments[1].to, { 2, 0, 0 })
end

function T.slot_axis_segments_use_tile_space_under_the_instance_transform()
  local instance = nitroInstance({ transform = Matrix4.translate(5, 0, 0) })
  local segments = AnimationDebugOverlay.slotAxisSegments(instance)
  Assert.equal(#segments, 6, "two slots x three axes")
  -- Segments are sorted by slot: slot 0 first, then slot 1.
  -- Slot 1's origin is (0,2,0) tiles (node 1 at 32 model units / 16).
  local x = segments[4]
  assertClose(x.from, { 5, 2, 0 })
  assertClose(x.to, { 6, 2, 0 })
end

function T.axis_segments_are_empty_without_a_pose()
  local instance = genericInstance({ play = "DoorOpen", pose = false })
  Assert.equal(#AnimationDebugOverlay.nodeAxisSegments(instance), 0)
  Assert.equal(#AnimationDebugOverlay.slotAxisSegments(instance), 0)
end

return T
