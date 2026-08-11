-- Private acceptance test: the real-ROM checklist for
-- the Elm Lab <-> New Bark door pair and the player-house stair pair, driven
-- through the production runtime (FieldSession + FieldInput + FieldTransition
-- wired exactly like FieldState wires it, real compiled scenes, real animated
-- ModelInstances, and the production autosave path). Each checklist item:
--
--   walking near stairs does not transition early
--   stepping on the appropriate stair does
--   exterior door opens
--   player visibly enters
--   map swap happens only at black
--   interior/exterior destination door animates
--   player visibly exits
--   door closes
--   player does not appear trapped inside a closed model
--   pressing back immediately re-enters
--   no arrival bounce loop
--   final saved/autosaved player position is correct
--
-- Runs against every ready dump through the ROM layer.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldTransition = require("libs.engine.src.FieldTransition")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")
local MapProps = require("libs.engine.src.MapProps")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local SaveFs = require("libs.rom.src.SaveFs")

local T = {}

local TOWN_MAP_ID = 60
local LAB_MAP_ID = 61
local HOUSE_1F_MAP_ID = 63
local HOUSE_2F_MAP_ID = 64
local TOWN_DOOR_TILE = { x = 684, z = 393 }
local LAB_ENTRANCE_TILE = { x = 4, z = 14 }

-- The walk phases below hold a direction for enough ticks to complete one
-- tile step (FieldPlayer.WALK_STEP_TICKS) and then idle on the arrival tile.
local WALK_TICKS = FieldPlayer.WALK_STEP_TICKS + 2

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

-- One compiled scene: the runtime map, the animated ModelInstances, the
-- MapProps facade, and the sceneRuntime shim the session's locked-tick path
-- advances (updateAnimated) and the transition's doorAt reads (mapProps) --
-- the shape MapSceneLoader produces.
local function compileScene(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local instances = {}
  local instanceList = {}
  local placements = {}
  for _, inst in ipairs(assets.scene.buildingInstances or {}) do
    local desc = assert(assets.models[inst.modelKey], "placement model descriptor")
    if desc.kind == "nitro-dynamic" then
      local instance = ModelInstance.new(ModelDefinition.fromNitroDescriptor(desc, { key = inst.modelKey }))
      instances[inst.placementIndex] = instance
      instanceList[#instanceList + 1] = instance
      for _, clip in ipairs(desc.animations) do
        if clip.ambientLoop then
          instance:play(clip.name, { loopMode = "loop" })
        end
      end
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
  map.sceneRuntime = {
    mapProps = props,
    updateAnimated = function()
      for _, instance in ipairs(instanceList) do
        instance:updateFixed()
      end
    end,
  }
  return { map = map, props = props }
end

local function surfaceAt(map, fieldX, fieldZ)
  local localX, localZ = FieldCoordinates.fieldToLocal(map, fieldX, fieldZ)
  local candidates = map.terrain:candidatesAt(localX + 0.5, localZ + 0.5)
  Assert.isTrue(#candidates > 0, "spawn tile has terrain")
  return candidates[1].id
end

-- The production session harness: FieldSession + FieldInput + the real
-- FieldTransition wired like FieldState (doorAt over the scene's mapProps,
-- swap rebuilding the player and rebinding the session), so the locked-tick
-- path advances the real animated instances and the autosave path captures
-- the real final position.
local function newHarness(romFs, versionId, scenes, spawn)
  local maps = {}
  for mapId, scene in pairs(scenes) do
    maps[mapId] = scene.map
  end
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. tostring(mapId))
    end,
    protectMap = function() end,
    protectCells = function() end,
  }
  local player = FieldPlayer.new({
    currentMap = spawn.map,
    fieldX = spawn.x,
    fieldZ = spawn.z,
    surfaceId = surfaceAt(spawn.map, spawn.x, spawn.z),
    facing = spawn.facing,
  })
  local harness = {
    versionId = versionId,
    maps = maps,
    loader = loader,
    input = FieldInput.new(),
    player = player,
    swapCount = 0,
    preSwapPosition = nil,
    sounds = {},
    timeline = {},
    ticks = 0,
    walkingPoseTicks = 0,
    onTick = nil,
  }
  local session
  local transition
  transition = FieldTransition.new({
    loader = loader,
    doorAt = function(runtimeMap, fieldX, fieldZ)
      local props = runtimeMap.sceneRuntime and runtimeMap.sceneRuntime.mapProps
      if not props then
        return nil
      end
      return props:doorAt(runtimeMap, fieldX, fieldZ)
    end,
    playSound = function(soundId)
      harness.sounds[#harness.sounds + 1] = soundId
    end,
    swap = function(resolution, swapFacing)
      harness.swapCount = harness.swapCount + 1
      harness.preSwapPosition = { x = player.fieldX, z = player.fieldZ }
      player = FieldPlayer.new({
        currentMap = resolution.destinationMap,
        fieldX = resolution.fieldX,
        fieldZ = resolution.fieldZ,
        surfaceId = resolution.surfaceId,
        facing = swapFacing,
      })
      transition.player = player
      harness.player = player
      session.currentMap = resolution.destinationMap
      session.player = player
      session.actor = player
    end,
  })
  transition.player = player
  local camera = { updateFixed = function() end }
  local playerVisual = {
    updateFixed = function(_, walking)
      if walking then
        harness.walkingPoseTicks = harness.walkingPoseTicks + 1
      end
    end,
  }
  session = FieldSession.new({
    versionId = versionId,
    currentMap = spawn.map,
    actor = player,
    player = player,
    camera = camera,
    transition = transition,
    input = harness.input,
    playerVisual = playerVisual,
  })
  harness.session = session
  harness.transition = transition
  return harness
end

-- One fixed session tick with the current input, recording the phase timeline
-- and the walking pose-clock ticks, then the test's per-tick hook.
local function tick(harness)
  harness.ticks = harness.ticks + 1
  harness.session:updateFixed()
  local phase = harness.transition.phase
  if harness.timeline[phase] == nil then
    harness.timeline[phase] = harness.ticks
  end
  if harness.onTick then
    harness.onTick(harness)
  end
end

-- Drive the session until the transition finishes (phase idle + a completion
-- event), with a hard tick budget; consumes the completion like FieldState.
local function drive(harness, maxTicks)
  local ticks = 0
  while harness.transition.phase ~= "idle" and harness.transition.phase ~= "error" and ticks < maxTicks do
    tick(harness)
    ticks = ticks + 1
  end
  Assert.equal(harness.transition.phase, "idle", "the transition completes within the tick budget")
  Assert.notNil(harness.transition:consumeCompleted(), "the transition records a completion event")
end

-- The production autosave path: capture after completion (FieldState does this
-- on consumeCompleted), publish through the transactional store, reload, and
-- restore against the same compiled maps. Returns the record and the restore.
local function autosaveRoundTrip(harness)
  Assert.isTrue(FieldSave.canCapture(harness.session), "a stable idle boundary can be captured")
  local record = FieldSave.capture(harness.session, {
    avatarId = "hero",
  })
  local store = FieldSaveStore.new(SaveFs.forVersion(harness.versionId, FakeCache.new()), { avatars = { hero = true } })
  store:save(record)
  local loaded = assert(store:load(), "the published save reloads")
  local restored = assert(FieldSave.restore(loaded, harness.loader, harness.versionId), "the save restores")
  return record, restored
end

-- No-arrival-bounce check: a run of input-free ticks must leave the player on
-- the arrival tile with no new transition.
local function assertStable(harness, ticks)
  local startX, startZ = harness.player.fieldX, harness.player.fieldZ
  for _ = 1, ticks do
    tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "no arrival bounce loop")
  Assert.equal(harness.player.fieldX, startX, "the player stays on the arrival tile")
  Assert.equal(harness.player.fieldZ, startZ, "the player stays on the arrival tile")
  Assert.isNil(harness.transition.completed, "no transition restarts without input")
end

-- Town -> Lab: pressing north at the town door approach fires the DOOR warp;
-- the exterior door (member 26) opens, the player walks into the doorway, the
-- swap happens only at full black, the interior destination is static on the
-- real ROM (Elm Lab's interior door carries no animation-list records), the
-- player exits onto the lab floor, and the autosave lands on (4,13).
function T.town_to_lab_door_acceptance(romFs, versionId)
  local town = compileScene(romFs, "MAP_NEW_BARK")
  local lab = compileScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local harness = newHarness(romFs, versionId, { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab }, {
    map = town.map,
    x = 684,
    z = 394,
    facing = "north",
  })

  harness.input:press("north")
  tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the blocked town door starts the transition")
  harness.input:release("north")

  drive(harness, 500)

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.equal(harness.preSwapPosition.x, TOWN_DOOR_TILE.x, "the ingress commits onto the door tile")
  Assert.equal(harness.preSwapPosition.z, TOWN_DOOR_TILE.z, "the ingress commits onto the door tile")
  Assert.isTrue(harness.walkingPoseTicks > 0, "the player visibly walks (pose clock hears the ingress/egress)")

  -- The exterior source door opened to completion during the source fade.
  local door = assert(town.props:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.isTrue(
    town.props.controller:isFinished(assert(door.instance), "door.open"),
    "the exterior door opens to completion"
  )
  -- The interior destination is static on the real ROM (behavior 101
  -- entrance-south, not a door kind; Elm Lab's interior door model has no
  -- animation-list records), so there is no destination animation and no
  -- close wait -- the checklist's interior item only holds for buildings
  -- whose interior doors carry anim-list records (door_pc01, maq_dr01, ...).
  Assert.isNil(lab.props:doorAt(lab.map, LAB_ENTRANCE_TILE.x, LAB_ENTRANCE_TILE.z))
  Assert.isNil(harness.timeline.door_close, "a static interior destination has no close wait")

  Assert.equal(harness.player.fieldX, 4)
  Assert.equal(harness.player.fieldZ, 13, "the egress lands on the lab floor tile")
  Assert.equal(harness.player.motion, "idle")
  Assert.isFalse(harness.transition.locked, "input unlocks once the choreography completes")
  Assert.isNil(harness.transition.suppression, "door warps never carry coordinate suppression")

  local localX, localZ = FieldCoordinates.fieldToLocal(lab.map, 4, 13)
  Assert.isFalse(lab.map.collision:isBlockedLocal(localX, localZ), "the player is not trapped inside the model")

  local record, restored = autosaveRoundTrip(harness)
  Assert.equal(record.mapId, LAB_MAP_ID)
  Assert.equal(record.fieldX, 4)
  Assert.equal(record.fieldZ, 13)
  Assert.equal(restored.fieldX, 4)
  Assert.equal(restored.fieldZ, 13)

  assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 4)
  Assert.equal(harness.player.fieldZ, 13)
end

-- Lab -> Town: pressing south on the lab entrance fires the entrance-south
-- warp; the destination exterior town door animates open at the swap and
-- closes to completion (the close wait gates the input unlock), the player
-- egresses onto the walkable approach tile, and the autosave lands on
-- (684,394).
function T.lab_to_town_door_acceptance(romFs, versionId)
  local lab = compileScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local town = compileScene(romFs, "MAP_NEW_BARK")
  local harness = newHarness(romFs, versionId, { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab }, {
    map = lab.map,
    x = LAB_ENTRANCE_TILE.x,
    z = LAB_ENTRANCE_TILE.z,
    facing = "south",
  })

  -- Sample the destination door's open role while the destination fade-in
  -- runs (it opens at the swap, ahead of the egress).
  local doorOpenPlaying = false
  harness.onTick = function()
    if harness.transition.phase == "fade_in" then
      local door = town.props:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z)
      if door and door.instance and town.props.controller:isFinished(door.instance, "door.open") == false then
        doorOpenPlaying = true
      end
    end
  end

  harness.input:press("south")
  tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing south on the lab entrance starts the transition")
  harness.input:release("south")

  drive(harness, 500)
  harness.onTick = nil

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.isTrue(harness.walkingPoseTicks > 0, "the player visibly walks (pose clock hears the egress)")
  Assert.isTrue(doorOpenPlaying, "the exterior destination door animates open at the swap")

  local door = assert(town.props:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.notNil(harness.timeline.door_close, "the destination door close is waited")
  Assert.isTrue(
    town.props.controller:isFinished(assert(door.instance), "door.close"),
    "the destination door closes to completion"
  )

  Assert.equal(harness.player.fieldX, 684)
  Assert.equal(harness.player.fieldZ, 394, "the egress lands on the walkable approach tile")
  Assert.equal(harness.player.motion, "idle")
  Assert.isFalse(harness.transition.locked)
  Assert.isNil(harness.transition.suppression, "the exit door re-arms immediately")

  local localX, localZ = FieldCoordinates.fieldToLocal(town.map, 684, 394)
  Assert.isFalse(town.map.collision:isBlockedLocal(localX, localZ), "the player is not trapped on the door tile")

  local record, restored = autosaveRoundTrip(harness)
  Assert.equal(record.mapId, TOWN_MAP_ID)
  Assert.equal(record.fieldX, 684)
  Assert.equal(record.fieldZ, 394)
  Assert.equal(restored.fieldX, 684)
  Assert.equal(restored.fieldZ, 394)

  assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 684)
  Assert.equal(harness.player.fieldZ, 394)
end

-- Pressing back immediately re-enters (9.7): from the lab->town arrival tile
-- (684,394), pressing north toward the door starts a new legitimate
-- transition on the very next tick -- no coordinate suppression, no step
-- needed -- and the round trip completes back on the lab floor.
function T.pressing_back_reenters_immediately(romFs, versionId)
  local town = compileScene(romFs, "MAP_NEW_BARK")
  local lab = compileScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local harness = newHarness(romFs, versionId, { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab }, {
    map = town.map,
    x = 684,
    z = 394,
    facing = "south",
  })

  harness.input:press("north")
  tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "pressing back toward the door re-enters immediately")
  Assert.equal(harness.transition.sourceWarp.x, TOWN_DOOR_TILE.x)
  Assert.equal(harness.transition.sourceWarp.z, TOWN_DOOR_TILE.z)
  harness.input:release("north")

  drive(harness, 500)

  Assert.equal(harness.swapCount, 1)
  Assert.equal(harness.player.fieldX, 4)
  Assert.equal(harness.player.fieldZ, 13, "the round trip completes on the lab floor")
  Assert.isFalse(harness.transition.locked)
  Assert.isNil(harness.transition.suppression)

  local record, restored = autosaveRoundTrip(harness)
  Assert.equal(record.mapId, LAB_MAP_ID)
  Assert.equal(record.fieldX, 4)
  Assert.equal(record.fieldZ, 13)
  Assert.equal(restored.fieldX, 4)
  Assert.equal(restored.fieldZ, 13)

  assertStable(harness, 20)
end

-- Player-house stairs: walking along the row south of the stairs (and
-- pressing the gate direction adjacent to them) never transitions early;
-- stepping onto the stair tile and facing the gate direction does. The full
-- choreography runs (climb in place, stair sound per side, black-only swap,
-- no door animation) and the arrival tile is itself a standing stair warp:
-- no input means no bounce, the gate direction re-enters immediately.
function T.player_house_stairs_acceptance(romFs, versionId)
  local house1f = compileScene(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_1F")
  local house2f = compileScene(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
  local harness = newHarness(romFs, versionId, { [HOUSE_1F_MAP_ID] = house1f, [HOUSE_2F_MAP_ID] = house2f }, {
    map = house1f.map,
    x = 4,
    z = 4,
    facing = "west",
  })

  -- Walking near the stairs (the row south of the stair tile) never starts a
  -- transition: the step west onto (3,4) commits, and pressing the gate
  -- direction there cannot fire (the blocked tile ahead is a wall, not a
  -- door, and the standing tile is not the stair warp).
  harness.input:press("west")
  for _ = 1, WALK_TICKS do
    tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "walking near the stairs does not transition early")
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 4, "the near walk commits onto the row south of the stairs")
  harness.input:release("west")

  -- Stepping onto the appropriate stair: walk north onto the stair tile
  -- (3,3); the commit alone does not trigger (stairs are input-gated).
  harness.input:press("north")
  for _ = 1, WALK_TICKS do
    tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "stepping onto the stair tile alone does not trigger")
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3, "the player stands on the stair tile")
  harness.input:release("north")

  -- Facing the gate direction on the stair tile fires the stair warp.
  harness.input:press("west")
  tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the gate direction on the stairs triggers")
  harness.input:release("west")

  drive(harness, 500)

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.isNil(harness.timeline.door_close, "stairs never enter the door-close wait")
  Assert.equal(#harness.sounds, 2, "one stair sound per side")
  for _, id in ipairs(harness.sounds) do
    Assert.equal(id, FieldTransition.STAIR_SOUND, "the HGSS stair-climb sound id")
  end
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 4, "the ascent lands on the 2F stair tile")
  Assert.equal(harness.player.motion, "idle")
  Assert.isFalse(harness.transition.locked, "stairs finish at the end of the destination fade-in")
  Assert.isNil(harness.transition.suppression, "stair warps never carry coordinate suppression")

  local record, restored = autosaveRoundTrip(harness)
  Assert.equal(record.mapId, HOUSE_2F_MAP_ID)
  Assert.equal(record.fieldX, 3)
  Assert.equal(record.fieldZ, 4)
  Assert.equal(restored.fieldX, 3)
  Assert.equal(restored.fieldZ, 4)

  -- No bounce loop: the arrival tile is itself a standing stair warp, but
  -- with no input nothing re-fires.
  assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 4)

  -- Pressing back on the destination stair tile immediately re-enters.
  harness.input:press("west")
  tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "the destination stair tile re-enters immediately")
  harness.input:release("west")

  drive(harness, 500)

  Assert.equal(harness.swapCount, 2)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3, "the descent lands back on the 1F stair tile")
  Assert.isFalse(harness.transition.locked)

  local down = autosaveRoundTrip(harness)
  Assert.equal(down.mapId, HOUSE_1F_MAP_ID)
  Assert.equal(down.fieldX, 3)
  Assert.equal(down.fieldZ, 3)

  assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3)
end

return T
