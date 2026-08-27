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

function T.tests.held_player_has_no_stale_interpolation_during_mother_cutscene()
  withGame(TOWN, function(game)
    game:waitForFieldEntry()
    enterHouse(game)
    game:waitForFieldEntry()

    -- Reach the Mom cutscene's input-suppressed phase by letting the field
    -- script own the tick; no direct previousWorld mutation — assert the
    -- real held-interpolation invariant instead.
    local player = game.runtime.player
    local scheduler = game.runtime.scripts.scheduler
    local entered = false
    for _ = 1, 200 do
      if scheduler:playerInputLocked() then
        entered = true
        break
      end
      local snapshot = game:snapshot()
      if snapshot.dialogue.modal then
        game.runtime:pressAction()
        game:step()
        game.runtime:releaseAction()
      else
        game:step()
      end
    end
    Assert.isTrue(entered, "must reach the cutscene's playerInputLocked phase")

    -- While held, previousWorld must already be collapsed so every alpha samples
    -- the same stationary world.
    for _ = 1, 10 do
      game:step()
      if scheduler:playerInputLocked() then
        for _, alpha in ipairs({ 0, 0.25, 0.5, 0.75, 1 }) do
          local pos = player:renderPosition(alpha)
          Assert.near(pos.x, player.worldX, 1e-9, "held player must be stationary at alpha " .. alpha)
          Assert.near(pos.z, player.worldZ, 1e-9, "held player must be stationary at alpha " .. alpha)
        end
      end
    end
  end)
end

return T
