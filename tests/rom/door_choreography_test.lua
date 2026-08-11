-- Private target test: the door source/destination choreography against the
-- real HGSS dump, run through the
-- production FieldTransition with the real doorAt resolution (compile ->
-- MapProps -> ModelInstance -> semantic roles) and the real locomotion. Both
-- Elm Lab <-> New Bark directions must: lock input, open the animated town
-- door, script the player through the doorway, swap only at full black,
-- egress from the transition anchor onto a normal floor tile, close the
-- destination door, wait for the close, and unlock -- without coordinate
-- suppression, so pressing back toward the door re-arms immediately. Runs
-- against every ready dump through the ROM layer.

local Assert = require("tests.support.Assert")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldTransition = require("libs.engine.src.FieldTransition")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

local TOWN_SYMBOL = "MAP_NEW_BARK"
local LAB_SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN_MAP_ID = 60
local LAB_MAP_ID = 61
local TOWN_DOOR_MEMBER = 26

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

-- One compiled scene: the runtime map, the MapProps facade, and the animated
-- ModelInstances -- the shape MapSceneLoader produces.
local function compileScene(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local instances = {}
  local placements = {}
  for _, inst in ipairs(assets.scene.buildingInstances or {}) do
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
  return { map = map, props = props, instances = instances }
end

local function surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  Assert.isTrue(#candidates > 0, "spawn tile has terrain")
  return candidates[1].id
end

-- Drive one full choreography over the real pair. `spawn` places the source
-- player; the transition resolves the real source/destination doors and the
-- swap rebuilds the player like FieldState:_swapMap. Returns the final
-- player, the transition, and the first-tick phase timeline.
local function runChoreography(romFs, sourceScene, destinationScene, warp, facing, spawn)
  local sourceMap, destinationMap = sourceScene.map, destinationScene.map
  local maps = { [sourceMap.mapId] = sourceMap, [destinationMap.mapId] = destinationMap }
  local propsByMapId = { [sourceMap.mapId] = sourceScene.props, [destinationMap.mapId] = destinationScene.props }
  local instancesByMapId = {
    [sourceMap.mapId] = sourceScene.instances,
    [destinationMap.mapId] = destinationScene.instances,
  }
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. tostring(mapId))
    end,
    protectMap = function() end,
    protectCells = function() end,
  }

  local player = FieldPlayer.new({
    currentMap = sourceMap,
    fieldX = spawn.x,
    fieldZ = spawn.z,
    surfaceId = surfaceAt(sourceMap, spawn.x, spawn.z),
    facing = facing,
  })

  local transition
  local currentInstances = sourceScene.instances
  transition = FieldTransition.new({
    loader = loader,
    doorAt = function(runtimeMap, x, z)
      local props = propsByMapId[runtimeMap.mapId]
      if not props then
        return nil
      end
      return props:doorAt(runtimeMap, x, z)
    end,
    swap = function(resolution, swapFacing)
      Assert.equal(transition.fadeAlpha, 1, "the swap happens only at full black")
      player = FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = swapFacing,
      })
      transition.player = player
      currentInstances = instancesByMapId[resolution.destinationMap.mapId]
    end,
  })
  transition.player = player
  transition:start(sourceMap, warp, facing)

  -- The fixed-tick loop mirrors the session: the transition ticks, and while
  -- the door choreography is active the scene's animated instances advance.
  local timeline = {}
  local ticks = 0
  while transition.phase ~= "idle" and transition.phase ~= "error" and ticks < 500 do
    ticks = ticks + 1
    transition:updateFixed()
    if transition.locked or transition.completed then
      for _, instance in ipairs(currentInstances) do
        instance:updateFixed()
      end
    end
    if timeline[transition.phase] == nil then
      timeline[transition.phase] = ticks
    end
  end
  Assert.equal(transition.phase, "idle", "the choreography completes within the tick budget")
  return transition, player, timeline
end

-- Town -> Lab: the source town door (member 26) opens and the player walks
-- north through the doorway; after the black swap the player egresses from
-- the interior anchor (4,14) onto the lab floor; the destination has no
-- animated door (Elm Lab's interior door is static), so nothing closes and
-- input unlocks right after the fade-in.
function T.town_to_lab_door_transition_choreographs(romFs, version)
  local town = compileScene(romFs, TOWN_SYMBOL)
  local lab = compileScene(romFs, LAB_SYMBOL)
  local warp = assert(WarpSystem.findAt(town.map, 684, 393))
  local transition, player, timeline = runChoreography(romFs, town, lab, warp, "north", {
    x = 684,
    z = 394,
  })

  -- The source door opened and the player committed onto the door tile
  -- before the swap (the scripted ingress), then egressed north off the
  -- interior anchor onto the lab floor.
  Assert.equal(player.fieldX, 4)
  Assert.equal(player.fieldZ, 13, "the egress walks north off the interior anchor")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked, "input unlocks once the choreography completes")
  Assert.isNil(transition.suppression, "door warps never carry coordinate suppression")
  Assert.isNil(timeline.door_close, "a static destination door has no close wait")
  Assert.isTrue(timeline.fade_out < timeline.swap_map, "the fade ran before the swap")
  Assert.equal(transition:consumeCompleted().sourceWarpId, warp.index)
end

-- Lab -> Town: the source side has no animated door (the interior entrance
-- is an entrance-south warp, not a door); the choreography activates on the
-- destination door (the New Bark town door, member 26), which opens as the
-- player exits, closes behind them, and only then unlocks input. The player
-- must finish on the walkable tile south of the door -- not trapped on the
-- blocked door tile.
function T.lab_to_town_door_transition_choreographs(romFs, version)
  local lab = compileScene(romFs, LAB_SYMBOL)
  local town = compileScene(romFs, TOWN_SYMBOL)
  local warp = assert(WarpSystem.findAt(lab.map, 4, 14))
  local transition, player, timeline = runChoreography(romFs, lab, town, warp, "south", {
    x = 4,
    z = 14,
  })

  Assert.equal(player.fieldX, 684)
  Assert.equal(player.fieldZ, 394, "the egress lands on the walkable approach tile")
  Assert.equal(player.motion, "idle")
  Assert.isFalse(transition.locked)
  Assert.isNil(transition.suppression, "the exit door re-arms immediately")

  -- The destination door (member 26) opened and closed to completion.
  local door = assert(town.props:doorAt(town.map, 684, 393))
  Assert.isTrue(door.modelKey:find("outdoor:" .. TOWN_DOOR_MEMBER .. ":", 1, true) == 1, "the town door model")
  Assert.isTrue(
    town.props.controller:isFinished(assert(door.instance), "door.close"),
    "the destination door finished closing"
  )

  -- The final tile is a normal floor tile: walkable, off the blocked door.
  local localX, localZ = FieldCoordinates.fieldToLocal(town.map, 684, 394)
  Assert.isFalse(town.map.collision:isBlockedLocal(localX, localZ), "the player is not trapped on the door")
end

return T
