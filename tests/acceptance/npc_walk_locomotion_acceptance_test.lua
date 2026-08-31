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
    versionId = AcceptanceHarness.defaultVersion(),
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
          worldY = draw.world.y,
          worldZ = draw.world.z,
          pose = draw.pose,
          poseTick = draw.poseTick,
          facing = actor.facing,
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

    -- Facing must already read the travel direction while the mother is
    -- mid-step toward the next tile, not only once that tile commits.
    local DIRECTION_FOR_DELTA = {
      ["0:-1"] = "north",
      ["0:1"] = "south",
      ["-1:0"] = "west",
      ["1:0"] = "east",
    }
    local checkedFacing = 0
    for i = 2, #observations - 1 do
      local prev = observations[i - 1]
      local cur = observations[i]
      if
        cur.fieldX == prev.fieldX
        and cur.fieldZ == prev.fieldZ
        and (cur.worldX ~= prev.worldX or cur.worldZ ~= prev.worldZ)
      then
        for j = i + 1, #observations do
          local later = observations[j]
          if later.fieldX ~= prev.fieldX or later.fieldZ ~= prev.fieldZ then
            local key = (later.fieldX - prev.fieldX) .. ":" .. (later.fieldZ - prev.fieldZ)
            local expected = DIRECTION_FOR_DELTA[key]
            if expected then
              checkedFacing = checkedFacing + 1
              Assert.equal(
                cur.facing,
                expected,
                "mother must already face her travel direction while mid-step, not only after the tile commits"
              )
            end
            break
          end
        end
      end
    end
    Assert.isTrue(checkedFacing > 0, "must have observed at least one in-flight facing sample")

    -- While logically and visually stationary outside walk-in-place, the
    -- mother must not read as walking. Walk-in-place keeps fieldX/fieldZ and
    -- worldX/worldZ fixed too, but its render-only vertical bob keeps worldY
    -- moving; requiring worldY to also hold across the window is what
    -- distinguishes true standstill from an active walk-in-place cycle.
    local checkedIdle = 0
    for i = 4, #observations do
      local a, b, c, d = observations[i - 3], observations[i - 2], observations[i - 1], observations[i]
      local stationary = a.fieldX == b.fieldX
        and b.fieldX == c.fieldX
        and c.fieldX == d.fieldX
        and a.fieldZ == b.fieldZ
        and b.fieldZ == c.fieldZ
        and c.fieldZ == d.fieldZ
        and a.worldX == b.worldX
        and b.worldX == c.worldX
        and c.worldX == d.worldX
        and a.worldZ == b.worldZ
        and b.worldZ == c.worldZ
        and c.worldZ == d.worldZ
        and a.worldY == b.worldY
        and b.worldY == c.worldY
        and c.worldY == d.worldY
      if stationary then
        checkedIdle = checkedIdle + 1
        Assert.isFalse(d.pose == "walk", "mother must not show walking presentation while logically stationary")
      end
    end
    Assert.isTrue(checkedIdle > 0, "must have observed at least one stationary sample")
  end)
end

return T
