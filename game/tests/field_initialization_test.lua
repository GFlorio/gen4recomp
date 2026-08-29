-- Production-composed fresh field initialization contracts. These tests boot
-- the real cache-backed runtime and stop before presentation or GPU work.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "initialization", "avatar" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"

local function withFreshGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = TOWN,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "fresh initialization must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.fresh_field_world_starts_with_clean_event_state()
  withFreshGame(function(game)
    local eventState = assert(game.runtime.eventState, "fresh runtime must own an event state")
    Assert.deepEqual(
      eventState:serialize(),
      { flags = {}, vars = {} },
      "fresh boot must not seed event flags or variables"
    )

    -- Object actors are materialized by the map-entry lifecycle, not by the
    -- boot itself, so the entry runs to completion first. This object is one
    -- of the flag-guarded actors in the supported entry map: a clear flag
    -- means the production actor manager must keep it live.
    game:waitForFieldReady()
    local actor = assert(game.runtime.actors:getById("map:60:object:0"), "clear event state must retain the actor")
    local eventFlag = assert(actor.sourceEvent.eventFlag, "the actor must carry its source event flag")
    Assert.isFalse(eventState:isFlagSet(eventFlag), "fresh boot must not hide the actor through a seeded flag")
  end)
end

local function withFreshGender(gender, expectedId, expectedSpriteId)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local template = AcceptanceHarness.new().gameFactory(versionId, map)
      template.playerData.profile.gender = gender
      return template
    end,
  })
  local game
  local ok, err = xpcall(function()
    game = harness:boot({
      versionId = AcceptanceHarness.defaultVersion(),
      map = TOWN,
      save = "fresh",
    })
    Assert.equal(game.runtime.playerData.profile.gender, gender)
    Assert.equal(game.runtime.avatar.id, expectedId)
    Assert.equal(game.runtime.avatar.spriteId, expectedSpriteId)
  end, debug.traceback)
  if game then
    local closeOk, closeErr = pcall(function()
      game:close()
    end)
    if ok and not closeOk then
      ok, err = false, closeErr
    end
  end
  if not ok then
    error(err, 0)
  end
end

function T.tests.fresh_avatar_matches_each_validated_player_gender()
  withFreshGender(0, "hero", 0)
  withFreshGender(1, "heroine", 97)
end

return T
