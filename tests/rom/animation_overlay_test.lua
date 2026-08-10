-- Private target test: Epic 10 debugging overlays on the real ROM. The
-- AnimationDebugOverlay gather and axis-segment functions run over real
-- compiled models -- New Bark's door (member 26, NSBCA pair) and Elm's Lab
-- material prop (member 29, NSBTA) -- pinning the overlay data model: the
-- debugger snapshot provenance, the node-transform readout, the Nitro
-- matrix-slot stack from the pose, the draw sources, and the world-space
-- axis segments of the visualizations.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local PosePerformanceCounter = require("libs.engine.src.PosePerformanceCounter")
local RuntimeAllocationProfiler = require("libs.engine.src.RuntimeAllocationProfiler")
local AnimationDebugOverlay = require("libs.engine.src.AnimationDebugOverlay")

local T = {}

local function compileInto(romFs, symbol)
  local c = CacheFs.forVersion(romFs:version(), FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, symbol))
  MapCacheWriter.write(c, bundle)
  return c, bundle
end

local function descriptorOf(bundle, memberId)
  for _, desc in pairs(bundle.models) do
    if desc.memberId == memberId then
      return desc
    end
  end
  return nil
end

local function instanceOf(desc)
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  return ModelInstance.new(def), def
end

local function clipEntry(instance, clipName)
  for _, entry in ipairs(AnimationDebugOverlay.gatherInstance(instance).animations) do
    if entry.clipName == clipName then
      return entry
    end
  end
  return nil
end

local function assertFinite(v)
  for _, c in ipairs(v) do
    assert(math.abs(c) < 1e30, "non-finite overlay coordinate")
  end
end

-- The real exterior door: its overlay data carries the debugger snapshot
-- provenance, the node/slot/draw readouts from the pose, and the axis
-- segments track the scrubbed animation.
function T.new_bark_door_overlay_gathers_real_pose_data(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local desc = descriptorOf(bundle, 26)
  assert(desc and desc.dynamic, "wk_door3 dynamic descriptor")
  local instance = instanceOf(desc)

  instance:play("door.open")
  instance:play("door.close")
  instance:evaluatePose()
  local data = AnimationDebugOverlay.gatherInstance(instance)

  -- The snapshot provenance of the real door pair.
  Assert.equal(data.modelKey, desc.key)
  Assert.equal(data.backend, "nitro")
  local open = clipEntry(instance, "door_op")
  assert(open, "door_op snapshot entry")
  Assert.deepEqual(open.roles, { "door.open" })
  Assert.equal(open.format, "NSBCA")
  Assert.equal(open.memberId, 1, "source member in the shared build_anim archive")
  Assert.equal(open.frameCount, 8)
  Assert.isTrue(open.boundTargets >= 1, "the door clip binds its node")
  local close = clipEntry(instance, "door_cl")
  assert(close, "door_cl snapshot entry")
  Assert.equal(close.memberId, 2, "source member in the shared build_anim archive")

  -- The node readout: the door's root node writes matrix-stack slot 31 (the
  -- HGSS field-model convention) and is visible in the pose.
  assert(#data.nodes >= 1, "the door program has nodes")
  Assert.equal(data.nodes[1].index, 0)
  Assert.equal(data.nodes[1].slot, 31, "the door root node stores its matrix in slot 31")
  Assert.isTrue(data.nodes[1].visible)
  assertFinite(data.nodes[1].translation)

  -- The matrix-slot stack of the pose: the real door's NODEDESC carries the
  -- store-slot option 0 in addition to the node's own slot 31, so both
  -- slots hold the root matrix.
  Assert.equal(#data.slots, 2)
  Assert.equal(data.slots[1].slot, 0)
  Assert.equal(data.slots[2].slot, 31)
  assertFinite(data.slots[1].translation)
  for i = 1, 3 do
    Assert.isTrue(
      math.abs(data.slots[1].translation[i] - data.slots[2].translation[i]) < 1e-6,
      "the NODEDESC store slot and the node slot hold the same matrix"
    )
  end

  -- The draw resolves from the current SBC matrix ("draw" source).
  assert(#data.draws >= 1, "the door has dynamic mesh draws")
  Assert.equal(data.draws[1].source, "draw")
  Assert.equal(data.draws[1].transformMode, "static")
  assertFinite(data.draws[1].translation)

  -- Scrubbing changes the draw: the pivot rotation sweeps the matrix cells
  -- while the node translation stays at the hinge. A fresh instance playing
  -- only door.open (both roles would blend to a fixed midpoint).
  local scrub = instanceOf(desc)
  scrub:play("door.open")
  scrub:evaluatePose()
  local data0 = AnimationDebugOverlay.gatherInstance(scrub)
  local draw0 = {}
  for i = 1, 9 do
    draw0[i] = data0.draws[1].matrix[i]
  end
  for _ = 1, 7 do
    scrub:updateFixed()
  end
  scrub:evaluatePose()
  data = AnimationDebugOverlay.gatherInstance(scrub)
  Assert.equal(clipEntry(scrub, "door_op").frame, 7)
  local differs = false
  for i = 1, 9 do
    if math.abs(data.draws[1].matrix[i] - draw0[i]) > 1e-3 then
      differs = true
    end
  end
  Assert.isTrue(differs, "the scrubbed door draw differs from frame 0")

  -- The world-space axis visualizations: one axis triple per node and per
  -- populated slot, with finite coordinates.
  local nodeSegments = AnimationDebugOverlay.nodeAxisSegments(instance)
  Assert.equal(#nodeSegments, 3 * #data.nodes)
  for _, segment in ipairs(nodeSegments) do
    assertFinite(segment.from)
    assertFinite(segment.to)
  end
  local slotSegments = AnimationDebugOverlay.slotAxisSegments(instance)
  Assert.equal(#slotSegments, 3 * #data.slots)
end

-- The real material prop (machine_l03, NSBTA): the overlay gathers the
-- material clip alongside the pose readouts; the node transform
-- visualization works on a material-animated model too.
function T.elms_lab_material_prop_overlay_gathers_its_clip(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local desc = descriptorOf(bundle, 29)
  assert(desc and desc.dynamic, "machine_l03 dynamic descriptor")
  local instance = instanceOf(desc)
  instance:play("machine_l03")
  instance:evaluatePose()

  local data = AnimationDebugOverlay.gatherInstance(instance)
  local entry = clipEntry(instance, "machine_l03")
  assert(entry, "machine_l03 snapshot entry")
  Assert.equal(entry.format, "NSBTA")
  Assert.equal(entry.memberId, 32, "source member in the shared build_anim archive")
  Assert.equal(entry.frameCount, 61)

  assert(#data.nodes >= 1, "the material-only model still poses nodes")
  assert(#data.slots >= 1, "the material-only model still populates matrix slots")
  assert(#AnimationDebugOverlay.nodeAxisSegments(instance) == 3 * #data.nodes)
end

-- The scene-level gather over a real instance: pose-performance rows are
-- named by model key and placement, and the allocation report passes
-- through.
function T.overlay_gathers_scene_observability_over_a_real_instance(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local desc = descriptorOf(bundle, 26)
  assert(desc and desc.dynamic, "wk_door3 dynamic descriptor")
  local perf = PosePerformanceCounter.new()
  local instance =
    ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = desc.key }), { performance = perf })
  instance.placementIndex = 26
  instance:play("door.open")
  instance:evaluatePose()
  instance:drawItems({ ["draw0.seg0"] = {} })
  local alloc = RuntimeAllocationProfiler.new()
  alloc:add("pose", 1)
  local runtime = {
    scene = { mapId = 61, mapSymbol = "MAP_NEW_BARK" },
    timeBand = "day",
    stats = { animatedInstances = 1, animatedModelCount = 1 },
    animatedInstances = { instance },
    perf = perf,
    alloc = alloc,
  }
  local data = AnimationDebugOverlay.gather(runtime)
  Assert.equal(data.scene.mapId, 61)
  Assert.equal(data.scene.timeBand, "day")
  Assert.equal(data.scene.animatedInstances, 1)
  Assert.equal(#data.perf, 2, "pose + material rows")
  Assert.equal(data.perf[1].key, desc.key .. "#26")
  Assert.equal(data.perfTotals.pose, 1)
  Assert.equal(data.alloc[1].site, "pose")
  Assert.equal(#data.instances, 1)
  Assert.equal(data.instances[1].label, desc.key .. "#26")
end

return T
