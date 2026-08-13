-- Private acceptance test: the real-ROM checklist for the Elm Lab <-> New
-- Bark door pair and the player-house stair pair, driven through the
-- production runtime (FieldSession + FieldInput + FieldTransition wired
-- exactly like FieldState) over scenes loaded through the REAL MapSceneLoader
-- with only the filesystem/rendering boundaries substituted (in-memory cache,
-- fake mesh/image builders). Each checklist item:
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
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldTransition = require("libs.engine.src.FieldTransition")
local SceneLoaderFixture = require("tests.rom.support.SceneLoaderFixture")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {}

local TOWN_MAP_ID = 60
local LAB_MAP_ID = 61
local HOUSE_1F_MAP_ID = 63
local HOUSE_2F_MAP_ID = 64
local TOWN_DOOR_TILE = { x = 684, z = 393 }
local LAB_ENTRANCE_TILE = { x = 4, z = 14 }
local OPEN_ROLE = "door.open"
local CLOSE_ROLE = "door.close"

-- The walk phases below hold a direction for enough ticks to complete one
-- tile step (FieldPlayer.WALK_STEP_TICKS) and then idle on the arrival tile.
local WALK_TICKS = FieldPlayer.WALK_STEP_TICKS + 2

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

-- Town -> Lab: pressing north at the town door approach fires the DOOR warp;
-- the exterior door (member 26) opens, the player walks into the doorway, the
-- swap happens only at full black, the interior destination is static on the
-- real ROM (Elm Lab's interior door carries no animation-list records), the
-- player exits onto the lab floor, and the autosave lands on (4,13).
function T.town_to_lab_door_acceptance(romFs, versionId)
  local town = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK")
  local lab = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = town.map, x = 684, z = 394, facing = "north" },
  })

  harness.input:press("north")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the blocked town door starts the transition")
  harness.input:release("north")

  SceneLoaderFixture.drive(harness, 500)

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.equal(harness.preSwapPosition.x, TOWN_DOOR_TILE.x, "the ingress commits onto the door tile")
  Assert.equal(harness.preSwapPosition.z, TOWN_DOOR_TILE.z, "the ingress commits onto the door tile")
  Assert.isTrue(harness.walkingPoseTicks > 0, "the player visibly walks (pose clock hears the ingress/egress)")

  -- The exterior source door opened to completion during the source fade.
  local door = assert(town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.isTrue(door:isFinished(), "the exterior door opens to completion")
  -- The interior destination is static on the real ROM (behavior 101
  -- entrance-south, not a door kind; Elm Lab's interior door model has no
  -- animation-list records), so there is no destination animation and no
  -- close wait -- the checklist's interior item only holds for buildings
  -- whose interior doors carry anim-list records (door_pc01, maq_dr01, ...).
  Assert.isNil(lab.runtime.mapProps:doorAt(lab.map, LAB_ENTRANCE_TILE.x, LAB_ENTRANCE_TILE.z))
  Assert.isNil(harness.timeline.choreo_hold, "a static interior destination has no close wait")

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

  SceneLoaderFixture.assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 4)
  Assert.equal(harness.player.fieldZ, 13)

  town.runtime:release()
  lab.runtime:release()
end

-- Lab -> Town: pressing south on the lab entrance fires the entrance-south
-- warp; the destination exterior town door animates open at the swap and
-- closes to completion (the close wait gates the input unlock), the player
-- egresses onto the walkable approach tile, and the autosave lands on
-- (684,394).
function T.lab_to_town_door_acceptance(romFs, versionId)
  local lab = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local town = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK")
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = lab.map, x = LAB_ENTRANCE_TILE.x, z = LAB_ENTRANCE_TILE.z, facing = "south" },
  })

  -- Sample the destination door's open role while the destination fade-in
  -- runs (it opens at the swap, ahead of the egress).
  local doorOpenPlaying = false
  harness.onTick = function(h)
    if h.transition.phase == "fade_in" then
      local door = town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z)
      if door and SceneLoaderFixture.entryRole(door) == OPEN_ROLE and door:isFinished() == false then
        doorOpenPlaying = true
      end
    end
  end

  harness.input:press("south")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing south on the lab entrance starts the transition")
  harness.input:release("south")

  SceneLoaderFixture.drive(harness, 500)
  harness.onTick = nil

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.isTrue(harness.walkingPoseTicks > 0, "the player visibly walks (pose clock hears the egress)")
  Assert.isTrue(doorOpenPlaying, "the exterior destination door animates open at the swap")

  local door = assert(town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.notNil(harness.timeline.choreo_hold, "the destination door close is waited")
  Assert.isTrue(SceneLoaderFixture.entryRole(door) == CLOSE_ROLE, "the retained entry state records the closing role")
  Assert.isTrue(door:isFinished(), "the destination door closes to completion")

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

  SceneLoaderFixture.assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 684)
  Assert.equal(harness.player.fieldZ, 394)

  lab.runtime:release()
  town.runtime:release()
end

-- Pressing back immediately re-enters (9.7): from the lab->town arrival tile
-- (684,394), pressing north toward the door starts a new legitimate
-- transition on the very next tick -- no coordinate suppression, no step
-- needed -- and the round trip completes back on the lab floor.
function T.pressing_back_reenters_immediately(romFs, versionId)
  local town = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK")
  local lab = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = town.map, x = 684, z = 394, facing = "south" },
  })

  harness.input:press("north")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "pressing back toward the door re-enters immediately")
  Assert.equal(harness.transition.sourceWarp.x, TOWN_DOOR_TILE.x)
  Assert.equal(harness.transition.sourceWarp.z, TOWN_DOOR_TILE.z)
  harness.input:release("north")

  SceneLoaderFixture.drive(harness, 500)

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

  SceneLoaderFixture.assertStable(harness, 20)

  town.runtime:release()
  lab.runtime:release()
end

-- Player-house stairs: walking along the row south of the stairs (and
-- pressing the gate direction adjacent to them) never transitions early;
-- stepping onto the stair tile and facing the gate direction does. The full
-- choreography runs (climb in place, stair sound per side, black-only swap,
-- no door animation) and the arrival tile is itself a standing stair warp:
-- no input means no bounce, the gate direction re-enters immediately.
function T.player_house_stairs_acceptance(romFs, versionId)
  local house1f = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_1F")
  local house2f = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [HOUSE_1F_MAP_ID] = house1f, [HOUSE_2F_MAP_ID] = house2f },
    spawn = { map = house1f.map, x = 4, z = 4, facing = "west" },
  })

  -- Walking near the stairs (the row south of the stair tile) never starts a
  -- transition: the step west onto (3,4) commits, and pressing the gate
  -- direction there cannot fire (the blocked tile ahead is a wall, not a
  -- door, and the standing tile is not the stair warp).
  harness.input:press("west")
  for _ = 1, WALK_TICKS do
    SceneLoaderFixture.tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "walking near the stairs does not transition early")
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 4, "the near walk commits onto the row south of the stairs")
  harness.input:release("west")

  -- Stepping onto the appropriate stair: walk north onto the stair tile
  -- (3,3); the commit alone does not trigger (stairs are input-gated).
  harness.input:press("north")
  for _ = 1, WALK_TICKS do
    SceneLoaderFixture.tick(harness)
  end
  Assert.equal(harness.transition.phase, "idle", "stepping onto the stair tile alone does not trigger")
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3, "the player stands on the stair tile")
  harness.input:release("north")

  -- Facing the gate direction on the stair tile fires the stair warp.
  harness.input:press("west")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the gate direction on the stairs triggers")
  harness.input:release("west")

  SceneLoaderFixture.drive(harness, 500)

  Assert.equal(harness.swapCount, 1, "exactly one map swap")
  Assert.isNil(harness.timeline.choreo_hold, "stairs never enter the door-close wait")
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
  SceneLoaderFixture.assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 4)

  -- Pressing back on the destination stair tile immediately re-enters.
  harness.input:press("west")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "the destination stair tile re-enters immediately")
  harness.input:release("west")

  SceneLoaderFixture.drive(harness, 500)

  Assert.equal(harness.swapCount, 2)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3, "the descent lands back on the 1F stair tile")
  Assert.isFalse(harness.transition.locked)

  local down = autosaveRoundTrip(harness)
  Assert.equal(down.mapId, HOUSE_1F_MAP_ID)
  Assert.equal(down.fieldX, 3)
  Assert.equal(down.fieldZ, 3)

  SceneLoaderFixture.assertStable(harness, 20)
  Assert.equal(harness.player.fieldX, 3)
  Assert.equal(harness.player.fieldZ, 3)

  house1f.runtime:release()
  house2f.runtime:release()
end

return require("tests.rom.support.RomSuite").fromFacts(T)
