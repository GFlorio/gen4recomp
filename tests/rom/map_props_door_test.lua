-- Private target test: the door/model lookup against the real HGSS dump.
-- Every New Bark town door (DOOR behavior 105) resolves to the placed door
-- model at its tile (members 24/25/26, compiled animated with the
-- door.open/door.close roles) and drives its animation to completion; Elm's
-- Lab interior entrance (WARP_ENTRANCE_SOUTH, 101) and non-door warp tiles
-- resolve nil. Runs only via --test-private.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")

local T = {}

local TOWN_DOORS = {
  { x = 684, z = 393, destinationMapId = 61, modelMemberId = 26 },
  { x = 695, z = 396, destinationMapId = 63, modelMemberId = 24 },
  { x = 679, z = 405, destinationMapId = 65, modelMemberId = 25 },
  { x = 690, z = 407, destinationMapId = 66, modelMemberId = 25 },
}

-- The model-space AABB of a descriptor's geometry (the loader stamps this
-- from the decoded .g4mesh assets; the private suite computes it from the
-- compiled bundle's mesh table).
local function footprintOf(desc, assets)
  local batches = desc.kind == "static" and desc.batches or desc.dynamic.batches
  local minX, maxX, minZ, maxZ
  for _, batch in ipairs(batches) do
    local sha = assert(batch.geometry:match("geometry/([%w]+)%.g4mesh"), "batch references .g4mesh geometry")
    local mesh = assert(assets.meshes[sha], "batch geometry present in the bundle")
    for _, v in ipairs(mesh.vertices) do
      minX = minX == nil and v.x or math.min(minX, v.x)
      maxX = maxX == nil and v.x or math.max(maxX, v.x)
      minZ = minZ == nil and v.z or math.min(minZ, v.z)
      maxZ = maxZ == nil and v.z or math.max(maxZ, v.z)
    end
  end
  return {
    minX = minX or 0,
    maxX = maxX or 0,
    minY = 0,
    maxY = 0,
    minZ = minZ or 0,
    maxZ = maxZ or 0,
  }
end

-- The scene's MapProps over the compiled bundle, mirroring MapSceneLoader:
-- every placement whose model descriptor is animated becomes a ModelInstance,
-- and every placement carries the model-space AABB the strict door lookup
-- tests containment against.
local function propsFor(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local scene = assets.scene
  local instances = {}
  local placements = {}
  for _, inst in ipairs(scene.buildingInstances or {}) do
    local desc = assert(assets.models[inst.modelKey], "placement model descriptor")
    if desc.kind == "nitro-dynamic" then
      instances[inst.placementIndex] =
        ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = inst.modelKey }))
    end
    placements[#placements + 1] = {
      placementIndex = inst.placementIndex,
      modelKey = inst.modelKey,
      transform = inst.transform,
      bounds = footprintOf(desc, assets),
    }
  end
  local map = RomRuntimeMap.compile(romFs, symbol)
  local props = MapProps.new({
    placements = placements,
    instances = instances,
    controller = MapPropAnimationController.new(),
  })
  return props, map, instances
end

-- The door at (x, z) resolved to the placement whose model member id matches.
local function doorAtMember(props, map, x, z, memberId, destinationMapId)
  local door = assert(props:doorAt(map, x, z), "door tile (" .. x .. "," .. z .. ") resolves")
  Assert.equal(door.x, x)
  Assert.equal(door.z, z)
  Assert.isTrue(door.modelKey:find("outdoor:" .. memberId .. ":", 1, true) == 1, "door model member " .. memberId)
  local instance = assert(door.instance, "the door model is animated")
  Assert.notNil(instance.definition:animation("door.open"))
  Assert.notNil(instance.definition:animation("door.close"))
  Assert.equal(assert(door.warp).destinationMapId, destinationMapId)
  return door
end

function T.new_bark_town_doors_resolve_to_their_placed_models(romFs)
  local props, map = propsFor(romFs, "MAP_NEW_BARK")
  for _, expected in ipairs(TOWN_DOORS) do
    doorAtMember(props, map, expected.x, expected.z, expected.modelMemberId, expected.destinationMapId)
  end
end

function T.new_bark_lab_door_plays_to_completion(romFs)
  local props, map, instances = propsFor(romFs, "MAP_NEW_BARK")
  local door = assert(props:doorAt(map, 684, 393))
  local instance = assert(door.instance)
  Assert.equal(instance, instances[door.placementIndex])
  door:open()
  Assert.isFalse(door:isFinished(), "freshly opened door is not finished")
  local frameCount = assert(instance.definition:animation("door.open")).frameCount
  for _ = 1, frameCount - 1 do
    instance:updateFixed()
  end
  Assert.isTrue(door:isFinished(), "the door reaches its last frame")
  door:close()
  for _ = 1, frameCount - 1 do
    instance:updateFixed()
  end
  Assert.isTrue(door:isFinished(), "the door closes")
end

function T.interior_entrances_and_non_door_warps_resolve_nil(romFs)
  local labProps, labMap = propsFor(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.isNil(labProps:doorAt(labMap, 4, 14), "Elm Lab's entrance-south tile is not a door lookup")

  local townProps, townMap = propsFor(romFs, "MAP_NEW_BARK")
  Assert.isNil(townProps:doorAt(townMap, 688, 392), "the WARP_WEST tile is not a door lookup")
  Assert.isNil(townProps:doorAt(townMap, 684, 394), "the walkable tile south of the lab door is not a door lookup")
end

return T
