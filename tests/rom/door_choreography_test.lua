-- Private target test: the door source/destination choreography against the
-- real HGSS dump, driven through the production composition (FieldSession +
-- FieldTransition wired like FieldState) over a scene loaded through the REAL
-- MapSceneLoader -- only the filesystem and rendering boundaries are
-- substituted (in-memory cache, fake mesh/image builders). Both Elm Lab <->
-- New Bark directions must run the HGSS event order -- open-start,
-- open-finished, player-step-start, player-step-finished, close-start,
-- close-finished -- observed through the REAL door handles' retained entry
-- state and the REAL player's motion, not reconstructed through hand-built
-- MapProps/ModelInstance plumbing. Door warps skip coordinate suppression, so
-- pressing back toward the door re-arms immediately. Runs against every ready
-- dump through the ROM layer.

local Assert = require("tests.support.Assert")
local SceneLoaderFixture = require("tests.private.support.SceneLoaderFixture")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

local TOWN_MAP_ID = 60
local LAB_MAP_ID = 61
local TOWN_DOOR_TILE = { x = 684, z = 393 }
local LAB_ENTRANCE_TILE = { x = 4, z = 14 }
local OPEN_ROLE = "door.open"
local CLOSE_ROLE = "door.close"

-- The two real scenes through the loader fixture.
local function townAndLab(romFs)
  local town = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK")
  local lab = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  return town, lab
end

-- The full HGSS event trace over one door warp, from the real handles.
local function driveDoorTrace(harness, maxTicks)
  SceneLoaderFixture.drive(harness, maxTicks)
  return table.concat(harness.events, ",")
end

-- Press the facing direction, confirm the transition starts, release, and
-- drive to completion.
local function pressAndDrive(harness, facing, maxTicks)
  harness.input:press(facing)
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the door starts the transition")
  harness.input:release(facing)
  return driveDoorTrace(harness, maxTicks)
end

-- Town -> Lab: the source town door (member 26) opens, the ingress step waits
-- for the opening to finish, the player commits onto the door tile, and the
-- swap happens only at full black. The destination interior entrance is
-- static on the real ROM (Elm Lab's interior door carries no animation-list
-- records), so the egress begins at the swap and nothing closes -- the trace
-- is two open->step pairs with no close.
function T.town_to_lab_door_transition_choreographs(romFs, versionId)
  local town, lab = townAndLab(romFs)
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = town.map, x = 684, z = 394, facing = "north" },
    doorTiles = { [TOWN_MAP_ID] = TOWN_DOOR_TILE, [LAB_MAP_ID] = LAB_ENTRANCE_TILE },
  })

  local trace = pressAndDrive(harness, "north", 500)
  Assert.equal(
    trace,
    "open-start,open-finished,step-start,step-finished,step-start,step-finished",
    "the town door opens, the ingress waits for it, and the static interior egresses without a close (got: "
      .. trace
      .. ")"
  )

  -- The source door opened to completion during the source fade.
  local door = assert(town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.isTrue(door:isFinished(), "the source door opens to completion")
  Assert.isTrue(SceneLoaderFixture.entryRole(door) == OPEN_ROLE, "the retained entry state records the played role")

  Assert.equal(harness.player.fieldX, 4)
  Assert.equal(harness.player.fieldZ, 13, "the egress walks north off the interior anchor")
  Assert.equal(harness.player.motion, "idle")
  Assert.isFalse(harness.transition.locked, "input unlocks once the choreography completes")
  Assert.isNil(harness.transition.suppression, "door warps never carry coordinate suppression")
  Assert.isNil(harness.timeline.door_close, "a static destination door has no close wait")
  Assert.isTrue(harness.timeline.fade_out < harness.timeline.swap_map, "the fade ran before the swap")
  local warp = assert(WarpSystem.findAt(town.map, 684, 393))
  Assert.equal(warp.destinationMapId, LAB_MAP_ID, "the town door tile is the lab warp")

  town.runtime:release()
  lab.runtime:release()
end

-- Lab -> Town: the source side has no animated door (the interior entrance is
-- an entrance-south warp, not a door), so the choreography activates on the
-- destination door (the New Bark town door, member 26): it opens at the swap,
-- the egress waits for the opening, the close begins only after the egress
-- movement finished, and the close completion gates the unlock -- the full
-- ordered trace, ending with the player on the walkable tile south of the
-- door, not trapped on the blocked door tile.
function T.lab_to_town_door_transition_choreographs(romFs, versionId)
  local town, lab = townAndLab(romFs)
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = lab.map, x = LAB_ENTRANCE_TILE.x, z = LAB_ENTRANCE_TILE.z, facing = "south" },
    doorTiles = { [TOWN_MAP_ID] = TOWN_DOOR_TILE, [LAB_MAP_ID] = LAB_ENTRANCE_TILE },
  })

  local trace = pressAndDrive(harness, "south", 500)
  Assert.equal(
    trace,
    "open-start,open-finished,step-start,step-finished,close-start,close-finished",
    "the destination door opens, the egress waits for it, and the close waits for the egress (got: " .. trace .. ")"
  )

  Assert.notNil(harness.timeline.door_close, "the destination door close is waited")

  local door = assert(town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z))
  Assert.isTrue(SceneLoaderFixture.entryRole(door) == CLOSE_ROLE, "the retained entry state records the closing role")
  Assert.isTrue(door:isFinished(), "the destination door finished closing")

  Assert.equal(harness.player.fieldX, 684)
  Assert.equal(harness.player.fieldZ, 394, "the egress lands on the walkable approach tile")
  Assert.equal(harness.player.motion, "idle")
  Assert.isFalse(harness.transition.locked)
  Assert.isNil(harness.transition.suppression, "the exit door re-arms immediately")

  local localX, localZ = FieldCoordinates.fieldToLocal(town.map, 684, 394)
  Assert.isFalse(town.map.collision:isBlockedLocal(localX, localZ), "the player is not trapped on the door")
  local warp = assert(WarpSystem.findAt(lab.map, 4, 14))
  Assert.equal(warp.destinationMapId, TOWN_MAP_ID, "the lab entrance is the town warp")

  town.runtime:release()
  lab.runtime:release()
end

-- The destination egress is gated on the door's opening clip, not on the
-- swap: while the destination door opens inside the fade-in, the player stays
-- at the anchor, and the trace's step-start lands after open-finished.
function T.destination_egress_waits_for_the_door_to_finish_opening(romFs, versionId)
  local town, lab = townAndLab(romFs)
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = lab.map, x = LAB_ENTRANCE_TILE.x, z = LAB_ENTRANCE_TILE.z, facing = "south" },
    doorTiles = { [TOWN_MAP_ID] = TOWN_DOOR_TILE, [LAB_MAP_ID] = LAB_ENTRANCE_TILE },
  })

  -- While the destination fade-in runs after the swap, the town door's open
  -- role is playing and the player has not begun the egress step.
  local egressWaited = false
  harness.onTick = function(h)
    if h.transition.phase == "fade_in" and h.player.motion == "idle" then
      local door = town.runtime.mapProps:doorAt(town.map, TOWN_DOOR_TILE.x, TOWN_DOOR_TILE.z)
      if door and SceneLoaderFixture.entryRole(door) == OPEN_ROLE and door:isFinished() == false then
        egressWaited = true
      end
    end
  end

  harness.input:press("south")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the lab entrance starts the transition")
  harness.input:release("south")
  SceneLoaderFixture.drive(harness, 500)
  harness.onTick = nil

  Assert.isTrue(egressWaited, "the open role plays inside the fade-in while the player waits at the anchor")
  local trace = table.concat(harness.events, ",")
  local openIndex = trace:find("open-finished", 1, true)
  local stepIndex = trace:find("step-start", 1, true)
  Assert.isTrue(
    stepIndex ~= nil and openIndex ~= nil and openIndex < stepIndex,
    "the egress begins after the opening finished (got: " .. trace .. ")"
  )

  town.runtime:release()
  lab.runtime:release()
end

-- A deliberately broken door: the compiled door.open clip's terminal is
-- stretched far beyond the tick budget (the keys/tables are extended to stay
-- consistent, so the pose evaluation survives -- the opening simply never
-- finishes). The fixture must OBSERVE the stall through the event trace --
-- open-start recorded, open-finished never, the choreography parked locked
-- in the close wait. The old reconstruction-based suites only asserted final
-- states and could not see the missing open-finished event in the middle of
-- the sequence. (In its verification form this probe asserted the trace
-- completes and ran red for exactly this reason: the trace stalled at
-- open-start, phase door_close, input locked.)
function T.door_open_that_never_finishes_stalls_the_ordered_trace(romFs, versionId)
  local lab = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK_ELMS_LAB_1F")
  local town = SceneLoaderFixture.loadScene(romFs, "MAP_NEW_BARK", {
    editDescriptor = function(desc)
      if desc.kind == "nitro-dynamic" then
        for _, clip in ipairs(desc.animations) do
          if clip.semanticNames and clip.semanticNames[1] == OPEN_ROLE then
            clip.frameCount = 10000
            local compiled = clip.compiled
            local period = #compiled.rotData
            for i = period + 1, clip.frameCount do
              compiled.rotData[i] = compiled.rotData[((i - 1) % period) + 1]
            end
            local rot = compiled.targets[1].channels.rot
            for i = period + 1, clip.frameCount do
              rot.keys[i] = rot.keys[((i - 1) % period) + 1]
            end
            rot.limit = clip.frameCount
          end
        end
      end
    end,
  })
  local harness = SceneLoaderFixture.newHarness(versionId, {
    scenes = { [TOWN_MAP_ID] = town, [LAB_MAP_ID] = lab },
    spawn = { map = lab.map, x = LAB_ENTRANCE_TILE.x, z = LAB_ENTRANCE_TILE.z, facing = "south" },
    doorTiles = { [TOWN_MAP_ID] = TOWN_DOOR_TILE, [LAB_MAP_ID] = LAB_ENTRANCE_TILE },
  })

  harness.input:press("south")
  SceneLoaderFixture.tick(harness)
  Assert.equal(harness.transition.phase, "fade_out", "facing the lab entrance starts the transition")
  local ticks = 1
  while harness.transition.phase ~= "idle" and harness.transition.phase ~= "error" and ticks < 500 do
    SceneLoaderFixture.tick(harness)
    ticks = ticks + 1
  end
  harness.input:release("south")

  -- The stall is observed through the events, not through any final state:
  -- the opening started, never finished, and the choreography parked locked
  -- in the close wait instead of unlocking. Nothing else can appear in the
  -- trace: no egress step (the open gates it) and no close (the egress does).
  local trace = table.concat(harness.events, ",")
  Assert.equal(trace, "open-start", "the only observed event is the opening (trace: " .. trace .. ")")
  Assert.equal(harness.transition.phase, "door_close", "the choreography parks in the close wait")
  Assert.isTrue(harness.transition.locked, "input stays locked while the opening never finishes")

  town.runtime:release()
  lab.runtime:release()
>>>>>>> 9685302 (tests: drive door choreography through a real scene fixture)
end

return T
