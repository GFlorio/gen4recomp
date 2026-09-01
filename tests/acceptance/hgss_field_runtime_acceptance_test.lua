-- Production-composed HGSS field scenarios. The shared harness supplies the
-- real generated cache and isolates saves; only the audio device is replaced
-- with a deterministic host boundary where the scenario observes it.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "hgss", "composition" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local HOUSE_2F = "MAP_NEW_BARK_PLAYER_HOUSE_2F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }

---@param fn fun(game: table, context: unknown?)
---@param fieldOptions table|fun(versionId: string): (table, unknown?)|nil
local function withTownGame(fn, fieldOptions)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local options
    local context
    if type(fieldOptions) == "function" then
      local factory = fieldOptions --[[@as fun(versionId: string): (table, unknown?)]]
      options, context = factory(versionId)
    else
      options = fieldOptions
    end
    local game = harness:boot({
      versionId = versionId,
      map = TOWN,
      save = "fresh",
      fieldOptions = options,
    })
    local ok, err = xpcall(function()
      fn(game, context)
      Assert.equal(game:renderAttempts(), 0, "field acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

local function enterPlayerHouse(game)
  game:waitForFieldReady()
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
  game:waitForFieldReady()
end

local function withFreshHouse2F(fn)
  local harness = AcceptanceHarness.new()
  local defaultGameFactory = harness.gameFactory
  harness.gameFactory = function(versionId, map)
    local game = defaultGameFactory(versionId, map)
    game.location.fieldX = 3
    game.location.fieldZ = 4
    return game
  end
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = HOUSE_2F,
      save = "fresh",
      fieldOptions = { recordingScriptHosts = true },
    })
    local ok, err = xpcall(function()
      fn(game)
      Assert.equal(game:renderAttempts(), 0, "fresh downstairs acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.field_entry_moves_actors_and_transitions_through_the_real_runtime()
  withTownGame(function(game)
    local initial = game:waitForFieldReady()
    Assert.equal(initial.mapSymbol, TOWN)
    Assert.notNil(initial.coverage, "field entry must publish physical map coverage")
    Assert.isTrue(next(initial.actors) ~= nil, "field entry must activate ROM-derived actors")

    enterPlayerHouse(game)

    local settled = game:snapshot()
    Assert.equal(settled.mapSymbol, HOUSE_1F)
    Assert.equal(game.runtime.actors.currentMapId, settled.mapId)
    Assert.equal(game.runtime.scripts.initController.mapId, settled.mapId)
    Assert.isNil(game.runtime.errorText, "a production field transition must not fault")
  end)
end

function T.tests.fresh_player_house_downstairs_step_does_not_fault_actor_lock_handoff()
  withFreshHouse2F(function(game)
    local start = game:waitForFieldReady()
    Assert.equal(start.mapSymbol, HOUSE_2F)

    game:step({ direction = "west" })
    local transition = game:waitForTransition()

    Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
    game:waitForFieldReady()
    Assert.isNil(game.runtime.errorText, "fresh downstairs movement must not fault the actor lock query")
    Assert.equal(game:snapshot().mapSymbol, HOUSE_1F)
  end)
end

function T.tests.opening_script_and_field_audio_keep_production_tick_boundaries()
  withTownGame(function(game, output)
    Assert.isTrue(type(game.runtime.audio) == "table", "field composition must provide HGSS audio policy")
    game:advanceUntil("field music reaches the host boundary", function()
      return output:anyNonSilent()
    end, 240)

    local startCountBeforeEntry = #game:recordsNamed("script.started")
    enterPlayerHouse(game)
    local world = assert(game.runtime.scripts.worldState, "field composition must provide world state")
    Assert.equal(
      world:getVar(OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F),
      0,
      "the fresh field save must begin at the source opening-scene value"
    )
    local expectedScript = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F, 0),
      "the generated house map must provide its opening-scene rule"
    )
    local starts = game:recordsNamed("script.started")
    local startedDuringEntry = false
    for index = startCountBeforeEntry + 1, #starts do
      if starts[index].payload and starts[index].payload.scriptId == expectedScript then
        startedDuringEntry = true
        break
      end
    end
    Assert.isTrue(startedDuringEntry, "the production opening script must start during house entry")

    OpeningLifecycle.completeOpeningHouseScene(game)

    Assert.equal(world:getVar(OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F), 1)
    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "the opening script must publish its progression flags")
    end
    local ended = game:recordsForScript(expectedScript, "script.ended")
    Assert.equal(#ended, 1, "the opening script must publish one terminal result")
    Assert.isTrue(ended[1].payload.completed, "the opening script must complete without a runtime fault")
    Assert.isTrue(output:anyNonSilent(), "the composed field audio must reach the host boundary")
  end, function(_)
    local output = FakeAudioOutput.new()
    return {
      audioHost = "production",
      audioOutput = output,
      dayNight = function()
        return "day"
      end,
      recordingScriptHosts = true,
    },
      output
  end)
end

function T.tests.game_field_composition_preserves_state_across_a_real_restart()
  withTownGame(function(game)
    enterPlayerHouse(game)
    local before = game:save()
    game:restart({ save = "resume" })
    local resumed = game:waitForFieldReady()

    Assert.equal(resumed.mapSymbol, before.mapSymbol)
    Assert.equal(resumed.mapId, before.mapId)
    Assert.equal(resumed.player.fieldX, before.player.fieldX)
    Assert.equal(resumed.player.fieldZ, before.player.fieldZ)
    Assert.equal(resumed.player.facing, before.player.facing)
    Assert.equal(resumed.player.worldY, before.player.worldY)
    Assert.equal(resumed.coverage ~= nil, before.coverage ~= nil, "restart must preserve physical-coverage presence")
    if resumed.coverage then
      Assert.equal(resumed.coverage.anchorX, before.coverage.anchorX)
      Assert.equal(resumed.coverage.anchorZ, before.coverage.anchorZ)
    end
    Assert.isNil(game.runtime.errorText, "application field composition must reload without a runtime fault")
  end)
end

return T
