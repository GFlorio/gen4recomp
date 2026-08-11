-- Private target test: naturally animated vanilla HGSS
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
  Assert.equal(desc.schema, "g4-model-v2")
  Assert.equal(desc.kind, "nitro-dynamic")
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

  -- The controller's instance view sees the playing clip with its role.
  local entries = controller:animationsFor(instance)
  local openEntry
  for _, e in ipairs(entries) do
    if e.name == "door_op" then
      openEntry = e
    end
  end
  assert(openEntry)
  Assert.deepEqual(openEntry.roles, { "door.open" })
  Assert.equal(openEntry.frameCount, 8)
end

-- Elm's Lab 1F places an interior prop with an NSBTA material animation
-- (member 29, machine_l03): the material clip compiles and the evaluator
-- produces its effective material state.
function T_elms_lab_material_prop_compiles_and_evaluates(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local desc = descriptorOf(bundle, 29)
  assert(desc, "machine_l03 descriptor present")
  Assert.equal(desc.schema, "g4-model-v2")
  Assert.equal(desc.kind, "nitro-dynamic")
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
  -- machine_l03 animates translation S from 0 to 2.0: the compiled keys
  -- ramp fx32 0 -> 0x2000 over the 61 frames. The normalized translation is
  -- the DS TEXCOORD value, so m02 = -transS / 4096 -- one fx32 unit is one
  -- texture width -- and the clip must reach -2.0 at its last frame, not
  -- -32.0 (the 1.11.4 TEXCOORD /16 the Maya <<4 factors compensate).
  local expected = { [15] = -0.5, [30] = -1.0, [60] = -2.0 }
  for frame, m02 in pairs(expected) do
    local runner = ModelInstance.new(def)
    runner:play("machine_l03")
    for _ = 1, frame do
      runner:updateFixed()
    end
    runner:evaluateMaterials()
    Assert.near(runner.materialState[target].texMatrix[7], m02, 1e-9, "machine_l03 m02 at frame " .. frame)
    Assert.near(runner.materialState[target].texMatrix[8], 0, 1e-9, "machine_l03 m12 at frame " .. frame)
  end
end

T.elms_lab_material_prop_compiles_and_evaluates = T_elms_lab_material_prop_compiles_and_evaluates

-- New Bark's exterior wind prop (member 28, wind_lm3/wind_lm4/wind_lm5,
-- 64x64, Maya) is a 120-frame NSBTA ambient loop. Its normalized matrix
-- translation is the DS TEXCOORD value -- one fx32 unit per texture width:
-- at frame 0 the compiled keys are transS = -2560 (0.625 texture widths)
-- and transT = 4096 (one texture width) on every wind material; the
-- wind_lm4 target's transS holds 0 at frame 45; the wind_lm3 target's
-- transT ramps to -4096 by frame 119 (m12 = -1.0). The pre-fix conversion
-- read 16x these values (m02 = 10, m12 = 16 at frame 0).
function T.new_bark_wind_clip_reaches_the_expected_uv_offsets(romFs, version)
  local _, bundle = compileInto(romFs, "MAP_NEW_BARK")
  local desc = descriptorOf(bundle, 28)
  assert(desc, "wind prop descriptor present")
  local wind
  for _, clip in ipairs(desc.animations) do
    if clip.name == "wind" then
      wind = clip
    end
  end
  assert(wind, "the wind clip is present")
  Assert.equal(wind.source.format, "NSBTA")
  Assert.equal(wind.frameCount, 120)

  local def = ModelDefinition.fromNitroDescriptor(desc, { key = desc.key })
  local byName = {}
  for i = 0, #def.materials - 1 do
    byName[def.materials[i + 1].name] = i
  end
  assert(byName.wind_lm3 and byName.wind_lm4 and byName.wind_lm5, "the three wind materials are present")
  local function atFrame(frame, materialName)
    local instance = ModelInstance.new(def)
    instance:play("wind")
    for _ = 1, frame do
      instance:updateFixed()
    end
    instance:evaluateMaterials()
    return instance.materialState[byName[materialName]].texMatrix
  end

  -- Frame 0: all three materials share transS = -2560, transT = 4096.
  for _, name in ipairs({ "wind_lm3", "wind_lm4", "wind_lm5" }) do
    local m = atFrame(0, name)
    Assert.near(m[7], 0.625, 1e-9, name .. " wind m02 at frame 0")
    Assert.near(m[8], 1.0, 1e-9, name .. " wind m12 at frame 0")
  end
  -- Frame 45: the wind_lm4 target's transS holds 0; wind_lm3 keeps -2560.
  Assert.near(atFrame(45, "wind_lm4")[7], 0, 1e-9, "wind_lm4 wind m02 at frame 45")
  Assert.near(atFrame(45, "wind_lm3")[7], 0.625, 1e-9, "wind_lm3 wind m02 at frame 45")
  -- Frame 119: wind_lm3's transT has ramped to -4096 -> m12 = -1.0.
  local m119 = atFrame(119, "wind_lm3")
  Assert.near(m119[7], 0.625, 1e-9, "wind_lm3 wind m02 at frame 119")
  Assert.near(m119[8], -1.0, 1e-9, "wind_lm3 wind m12 at frame 119")
end

-- The animation resource cache: New Bark and Route 12 both
-- place exterior door models (New Bark members 24/25/26, Route 12 member
-- 24) whose anim-list records reference the shared door_op/door_cl
-- resources. Compiled with one cache across a build run, both maps must
-- embed the IDENTICAL clip records -- each (archive, member, sha1) tuple
-- decodes and compiles exactly once.
function T.shared_resource_cache_reuses_clip_records_across_maps(romFs, version)
  local AnimationResourceCache = require("romdump.src.digest.AnimationResourceCache")
  local cache = AnimationResourceCache.new()
  local bundleA = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK", { resourceCache = cache }))
  local bundleB = assert(MapAssetCompiler.compile(romFs, "MAP_ROUTE_12", { resourceCache = cache }))
  local descA = descriptorOf(bundleA, 26)
  local descB = descriptorOf(bundleB, 24)
  assert(descA and descA.dynamic, "New Bark door descriptor")
  assert(descB and descB.dynamic, "Route 12 door descriptor")
  Assert.equal(#descA.animations, 2)
  Assert.equal(#descB.animations, 2)
  local byNameA, byNameB = {}, {}
  for _, clip in ipairs(descA.animations) do
    byNameA[clip.name] = clip
  end
  for _, clip in ipairs(descB.animations) do
    byNameB[clip.name] = clip
  end
  Assert.isTrue(byNameA.door_op == byNameB.door_op, "door_op compiled once, shared by identity")
  Assert.isTrue(byNameA.door_cl == byNameB.door_cl, "door_cl compiled once, shared by identity")

  -- Without a shared cache the compiles are independent records.
  local fresh = assert(MapAssetCompiler.compile(romFs, "MAP_ROUTE_12"))
  local freshDesc = assert(descriptorOf(fresh, 24), "Route 12 door descriptor")
  local freshClip
  for _, clip in ipairs(freshDesc.animations) do
    if clip.name == "door_op" then
      freshClip = clip
    end
  end
  Assert.isFalse(freshClip == byNameA.door_op, "a cacheless compile makes fresh records")
  Assert.equal(freshClip.name, byNameA.door_op.name)
  Assert.equal(freshClip.source.sha1, byNameA.door_op.source.sha1)
end

return T
