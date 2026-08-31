local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "ownership", "opening" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local HOUSE_EXIT_WARP = { fieldX = 3, fieldZ = 10 }
local VAR_SCENE_PLAYERS_HOUSE_1F = OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F
local FLAG_HIDE_NEW_BARK_FRIEND = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND
local FLAG_HIDE_NEW_BARK_MARILL = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_MARILL

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "field ownership acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

local function enterHouse(game)
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

local function leaveHouseToTown(game)
  -- Inside Player House 1F the south exit warp at (3,10) is a
  -- WARP_ENTRANCE_SOUTH standing trigger: press south while standing on the
  -- tile. Reach the tile first, then provide the trigger direction.
  game:moveTo({ fieldX = 3, fieldZ = 9 })
  -- Step onto the warp tile (3,10) and wait for the movement to settle.
  game:step({ direction = "south" })
  game:advanceUntil("player reaches the house exit warp tile", function(snapshot)
    return snapshot.player.motion == "idle"
      and snapshot.player.fieldX == HOUSE_EXIT_WARP.fieldX
      and snapshot.player.fieldZ == HOUSE_EXIT_WARP.fieldZ
  end, 60)
  -- Standing on the warp, press south to fire the direction-gated transition.
  game:step({ direction = "south" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, TOWN, "the house exit must return to New Bark town")
end

function T.tests.house_scene_completes_and_town_friend_scene_follows_through_real_exit()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 0, "a fresh world starts at scene 0")

    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")

    enterHouse(game)

    local expectedHouseScript = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 0),
      "House 1F must have an on_frame rule for scene 0"
    )
    game:advanceUntil("the opening scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 60)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(starts[baselineStarts + 1].payload.scriptId, expectedHouseScript)
    Assert.isTrue(game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil)

    OpeningLifecycle.completeOpeningHouseScene(game)
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 1, "Mom must advance the scene to 1")
    Assert.isNil(game.runtime.scripts.scheduler:foregroundEnvironmentId(), "ReleaseAll must free the field")

    -- Leave through the real door and observe the town friend scene.
    leaveHouseToTown(game)
    game:waitForFieldEntry()

    if game.runtime.errorText then
      error("field runtime faulted after house exit: " .. tostring(game.runtime.errorText))
    end

    local expectedFriendScript = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "New Bark must have a friend/Marill rule for scene 1"
    )

    -- The town lifecycle runs its on_transition ownership first; the friend
    -- rule starts only after that settles.
    game:advanceUntil("the friend/Marill scene starts", function()
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedFriendScript then
          return true
        end
      end
      return false
    end, 240)

    local friendStarts = {}
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedFriendScript then
        friendStarts[#friendStarts + 1] = record
      end
    end
    Assert.equal(#friendStarts, 1, "the friend/Marill scene must start exactly once")

    game:advanceUntil("the friend/Marill scene settles", function()
      return world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 2
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_FRIEND)
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL)
        and not game:snapshot().fieldLocked
        and game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
    end, 600)

    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 2)
    Assert.isTrue(world:isFlagSet(FLAG_HIDE_NEW_BARK_FRIEND))
    Assert.isTrue(world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL))
    Assert.isNil(
      game.runtime.scripts.scheduler:foregroundEnvironmentId(),
      "no foreground must remain after the friend scene"
    )
    Assert.isNil(game.runtime.errorText, "no runtime fault must have occurred")

    -- Friend (object 4, FLAG_HIDE_NEW_BARK_FRIEND=418) and Marill (object 3,
    -- FLAG_HIDE_NEW_BARK_MARILL=417) end absent/hidden as the scene dictates.
    -- Object 0 (flag 400, UNK_190) is unrelated to this scene; checking it
    -- would be a stale-index bug — Marill is object 3, not object 0.
    local snapshot = game:snapshot()
    for _, actorId in ipairs({ "map:60:object:4", "map:60:object:3" }) do
      local actor = snapshot.actors[actorId]
      if actor ~= nil then
        Assert.isTrue(false, actorId .. " must be absent after the scene")
      end
    end

    -- 30 idle ticks must not restart the scene.
    local before = #recordsNamed(game, "script.started")
    for _ = 1, 30 do
      game:step()
      if game.runtime.errorText then
        error("field runtime faulted during idle: " .. tostring(game.runtime.errorText))
      end
    end
    local after = #recordsNamed(game, "script.started")
    Assert.equal(after, before, "the settled friend scene must not restart over idle ticks")

    -- Player input must be usable on the next fresh tick.
    local posBefore = { x = game:snapshot().player.fieldX, z = game:snapshot().player.fieldZ }
    if game:snapshot().player.facing ~= "east" then
      game:face("east")
    end
    game:move("east")
    local moved = game:advanceUntil("player moves after scene", function(s)
      return s.player.fieldX ~= posBefore.x or s.player.fieldZ ~= posBefore.z
    end, 60)
    Assert.notNil(moved, "movement input must work after the scene releases the field")
  end, { recordingScriptHosts = true })
end

return T
