local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "opening", "locomotion" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local VAR_SCENE_PLAYERS_HOUSE_1F = OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function enterHouse(game)
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

local function findMotherId(game)
  for _, record in ipairs(game.runtime.actors:drawRecords()) do
    if record.spriteId == 365 then
      return record.actorId
    end
  end
  for actorId in pairs(game:snapshot().actors) do
    local actor = game.runtime.actors:getById(actorId)
    if actor and actor.spriteId == 365 then
      return actorId
    end
  end
  return nil
end

function T.tests.npc_walk_shows_intermediate_world_and_locomotion_frames()
  withGame(TOWN, function(game)
    game:waitForFieldEntry()
    enterHouse(game)
    game:waitForFieldEntry()

    local motherId = assert(findMotherId(game), "mother actor must be present in Player House 1F")
    local world = game.runtime.scripts.worldState

    local observations = {}
    for step = 1, 2400 do
      if game.runtime.errorText then
        error("runtime fault: " .. tostring(game.runtime.errorText))
      end
      local actor = game.runtime.actors:getById(motherId)
      local draw
      for _, r in ipairs(game.runtime.actors:drawRecords()) do
        if r.actorId == motherId then
          draw = r
          break
        end
      end
      if actor and draw then
        observations[#observations + 1] = {
          fieldX = actor.fieldX,
          fieldZ = actor.fieldZ,
          worldX = draw.world.x,
          worldZ = draw.world.z,
          pose = draw.pose,
          poseTick = draw.poseTick,
        }
      end
      local snapshot = game:snapshot()
      if
        world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 1
        and not snapshot.fieldLocked
        and game.runtime.scripts.scheduler:foregroundEnvironmentId() == nil
      then
        break
      end
      if snapshot.dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      else
        game:step()
      end
      if step == 2400 then
        error("mother scene did not complete")
      end
    end

    Assert.isTrue(#observations > 10, "must have sampled mother across scene")

    local foundIntermediate = false
    for i = 2, #observations do
      local prev = observations[i - 1]
      local cur = observations[i]
      if cur.fieldX == prev.fieldX and cur.fieldZ == prev.fieldZ then
        if cur.worldX ~= prev.worldX or cur.worldZ ~= prev.worldZ then
          foundIntermediate = true
          break
        end
      end
    end

    local foundWalk = false
    local foundTickAdvance = false
    local lastTick
    for _, obs in ipairs(observations) do
      if obs.pose == "walk" then
        foundWalk = true
      end
      if lastTick ~= nil and obs.pose == "walk" and obs.poseTick ~= lastTick then
        foundTickAdvance = true
      end
      lastTick = obs.poseTick
    end

    Assert.isTrue(
      foundIntermediate,
      "mother presentation must advance between tiles while committed field stays at source"
    )
    Assert.isTrue(foundWalk, "mother must use walking pose during walk")
    Assert.isTrue(foundTickAdvance, "mother pose clock must advance during walk")
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 1)
  end)
end

return T
