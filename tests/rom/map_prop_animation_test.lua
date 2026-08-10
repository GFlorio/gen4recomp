-- Private target test: Epic 8 acceptance -- naturally animated vanilla HGSS
-- field props compile through MapAssetCompiler into dynamic model
-- descriptors and animate through the production runtime. New Bark's
-- exterior places a door pair (wk_door3, member 26, NSBCA door_op/door_cl);
-- Elm's Lab 1F places an interior prop with a material animation
-- (member 29, NSBTA machine_l03). Both must compile into descriptors with
-- compiled clips and semantic roles, and the compiled clips must drive a
-- ModelInstance's pose and material state like the real resources.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MaterialEvaluator = require("libs.engine.src.MaterialEvaluator")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local AnimationDebugger = require("libs.engine.src.AnimationDebugger")

local T = {}

local function compileInto(romFs, symbol)
  local c = CacheFs.forVersion(romFs:version(), FakeCache.new())
  local bundle = assert(MapAssetCompiler.compile(romFs, symbol))
  MapCacheWriter.write(c, bundle)
  return c, bundle
end

-- Find the descriptor whose memberId matches, among the compiled models.
local function descriptorOf(bundle, memberId)
  for _, desc in pairs(bundle.models) do
    if desc.memberId == memberId then
      return desc
    end
  end
  return nil
end

-- The animated door of New Bark: member 26 (wk_door3) carries the NSBCA
-- door_op/door_cl pair through the exterior animation list.
function T.new_bark_door_compiles_as_animated(romFs, version)
  local c, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local desc = descriptorOf(bundle, 26)
  assert(desc, "wk_door3 descriptor present")
  Assert.equal(desc.backend, "nitro")
  assert(desc.dynamic, "door compiles through the dynamic path")
  assert(desc.dynamic.transformProgram)
  Assert.isTrue(#desc.dynamic.batches > 0, "door has dynamic segment meshes")

  -- Both clips compile with the door semantic roles.
  Assert.equal(#desc.animations, 2)
  local byName = {}
  for _, clip in ipairs(desc.animations) do
    byName[clip.name] = clip
  end
  assert(byName.door_op)
  assert(byName.door_cl)
  Assert.deepEqual(byName.door_op.semanticNames, { "door.open" })
  Assert.deepEqual(byName.door_cl.semanticNames, { "door.close" })
  Assert.equal(desc.roles["door.open"], "door_op")
  Assert.equal(desc.roles["door.close"], "door_cl")
  Assert.equal(byName.door_op.frameCount, 8)
  Assert.equal(byName.door_op.source.format, "NSBCA")
  Assert.equal(byName.door_op.source.archive, "build_anim")
  Assert.equal(byName.door_op.source.memberId, 1)

  -- Content addressing: the animation list and the clip resources are in
  -- the dependency record, so a changed animation invalidates the compile.
  Assert.isTrue(#bundle.dependencies.animationListMemberSha1s > 0)

  -- The scene instance references the animated descriptor and the cache
  -- round-trips it.
  local placed = false
  for _, inst in ipairs(bundle.scene.buildingInstances) do
    if inst.modelKey == desc.key then
      placed = true
    end
  end
  Assert.isTrue(placed, "the door is placed in the scene")
  Assert.isTrue(c:exists(MapAssetCache.modelPath(desc.key)), "descriptor on disk")
end

-- The compiled door drives a ModelInstance: the pose at the last frame is
-- the open door, the bind pose is closed.
function T.new_bark_door_animates_through_the_runtime(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local desc = descriptorOf(bundle, 26)
  assert(desc, "wk_door3 descriptor present")
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  local instance = ModelInstance.new(def)
  instance:play("door.open")
  instance:evaluatePose()
  local closed = instance.poseState.drawMatrices["draw0.seg0"].position
  for _ = 1, 7 do
    instance:updateFixed()
  end
  instance:evaluatePose()
  local open = instance.poseState.drawMatrices["draw0.seg0"].position
  -- The real door_op sweeps the pivot rotation across its 8 frames; the
  -- compiled rotation cells must differ from the bind pose.
  local differs = false
  for i = 1, 9 do
    if math.abs(open[i] - closed[i]) > 1e-3 then
      differs = true
    end
  end
  Assert.isTrue(differs, "scrubbed door pose differs from the closed pose")

  -- The controller drives the pair by semantic role.
  local controller = MapPropAnimationController.new()
  controller:play(instance, "door.open")
  for _ = 1, 7 do
    instance:updateFixed()
  end
  Assert.isTrue(controller:isFinished(instance, "door.open"), "door finished open")

  -- The debugger sees the playing clip with its provenance.
  local entries = AnimationDebugger.snapshot(instance)
  Assert.equal(#entries, 2)
  local openEntry
  for _, e in ipairs(entries) do
    if e.clipName == "door_op" then
      openEntry = e
    end
  end
  assert(openEntry)
  Assert.equal(openEntry.format, "NSBCA")
  Assert.equal(openEntry.frameCount, 8)
end

-- Elm's Lab 1F places an interior prop with an NSBTA material animation
-- (member 29, machine_l03): the material clip compiles and the evaluator
-- produces its effective material state.
function T_elms_lab_material_prop_compiles_and_evaluates(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local desc = descriptorOf(bundle, 29)
  assert(desc, "machine_l03 descriptor present")
  Assert.equal(desc.backend, "nitro")
  assert(desc.dynamic)
  Assert.equal(#desc.animations, 1)
  local clip = desc.animations[1]
  Assert.equal(clip.kind, "texsrt")
  Assert.equal(clip.name, "machine_l03")
  Assert.equal(clip.source.format, "NSBTA")
  Assert.equal(clip.frameCount, 61)

  -- The animated material carries the texture metadata the evaluator needs.
  local material = desc.materials[1]
  assert(material, "the animated material is present")
  assert(material.texMtxMode ~= nil)
  assert(material.polygonAlpha ~= nil)
  assert(material.texWidth ~= nil)

  -- The compiled clip drives the material state through the runtime. The
  -- BTA targets ma_l03_2 (the second material; the first, h_kage, is the
  -- model's shadow texture).
  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  local instance = ModelInstance.new(def)
  instance:play("machine_l03")
  instance:evaluateMaterials()
  local target = nil
  for i = 0, #def.materials - 1 do
    if def.materials[i + 1].name == "ma_l03_2" then
      target = i
    end
  end
  assert(target, "the animated material is present")
  local state = instance.materialState[target]
  assert(state.texMatrix, "effective texture matrix")
  -- machine_l03 animates translation S from 0 to 2.0: the matrix
  -- translation advances with the frames.
  local m0 = state.texMatrix[7]
  for _ = 1, 30 do
    instance:updateFixed()
  end
  instance:evaluateMaterials()
  Assert.isTrue(
    math.abs(instance.materialState[target].texMatrix[7] - m0) > 1e-4,
    "scrubbed material matrix differs from frame 0"
  )
end

T.elms_lab_material_prop_compiles_and_evaluates = T_elms_lab_material_prop_compiles_and_evaluates

return T
