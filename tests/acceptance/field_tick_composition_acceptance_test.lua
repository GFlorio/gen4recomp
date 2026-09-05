-- Production-composed fixed-tick field contracts. The harness supplies the
-- real generated maps, scripts, actors, and scheduler, and stops before draw.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local PlayTime = require("libs.hgss.src.save.PlayTime")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "fixed-tick", "composition" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_1F = "MAP_NEW_BARK_ELMS_LAB_1F"
local ELM_ACTOR_ID = "map:61:object:0"
local VAR_SCENE_ELMS_LAB = FieldScriptSymbols.variablesByName.VAR_SCENE_ELMS_LAB

local function labHarness()
  return AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      return {
        saveId = "save-00000001",
        versionId = versionId,
        location = { mapSymbol = map or LAB_1F, fieldX = 4, fieldZ = 13, facing = "north" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        playTime = PlayTime.new(),
        worldState = FieldEventState.new(),
      }
    end,
  })
end

local function withGame(harness, map, fn)
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "fixed-tick acceptance must stop before GPU rendering")
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

local function stepExactlyOnce(game)
  local before = game:snapshot()
  local after
  if before.dialogue.modal then
    game.runtime:pressAction()
    after = game:step()
    game.runtime:releaseAction()
  else
    after = game:step()
  end
  Assert.equal(after.tick, before.tick + 1, "one production harness step must execute one field tick")
  return before, after
end

function T.tests.foreground_field_script_preserves_phase_ownership_and_tick_cadence()
  withGame(labHarness(), LAB_1F, function(game)
    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")
    game:moveTo({ fieldX = 4, fieldZ = 10 })

    game:advanceUntil("the production lab welcome scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 60)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts, baselineStarts + 1, "the field-entry interaction must start one foreground script")
    local playerAtStart = game:snapshot().player
    local sawActorMovement = false
    local completed = false

    for _ = 1, 600 do
      local before, after = stepExactlyOnce(game)
      if after.fieldLocked then
        local elm = assert(after.actors[ELM_ACTOR_ID], "the foreground field script must retain its actor world")
        if before.actors[ELM_ACTOR_ID] then
          sawActorMovement = sawActorMovement
            or elm.fieldX ~= before.actors[ELM_ACTOR_ID].fieldX
            or elm.fieldZ ~= before.actors[ELM_ACTOR_ID].fieldZ
            or elm.facing ~= before.actors[ELM_ACTOR_ID].facing
        end
        Assert.equal(
          after.player.fieldX,
          playerAtStart.fieldX,
          "script ownership must precede ordinary player input for the tick"
        )
        Assert.equal(
          after.player.fieldZ,
          playerAtStart.fieldZ,
          "script ownership must keep ordinary player movement frozen"
        )
      end
      if not after.fieldLocked and game.runtime.scripts.worldState:getVar(VAR_SCENE_ELMS_LAB) == 1 then
        completed = true
        break
      end
    end

    Assert.isTrue(sawActorMovement, "the production script phase must still advance actor presentation")
    Assert.isTrue(completed, "the foreground field script must reach its source completion boundary")
    Assert.isFalse(game:snapshot().fieldLocked, "script completion must release field ownership")
    Assert.equal(#recordsNamed(game, "script.started"), baselineStarts + 1)
  end)
end

function T.tests.ordinary_field_movement_keeps_one_tile_and_settled_transition_behavior()
  withGame(AcceptanceHarness.new(), TOWN, function(game)
    OpeningLifecycle.settleNewBarkFriendScene(game)
    game:waitForFieldReady()
    game:moveTo({ fieldX = 682, fieldZ = 394 })
    game:face("east")
    local before = game:snapshot()
    local tickBefore = before.tick
    game:step({ direction = "east" })
    local after = game:advanceUntil("ordinary production movement settles", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 60)

    Assert.equal(after.player.fieldX, before.player.fieldX + 1, "ordinary movement must commit one tile")
    Assert.equal(after.player.fieldZ, before.player.fieldZ, "ordinary movement must preserve the other axis")
    Assert.equal(after.transition.phase, "idle", "ordinary movement must not create a transition")
    Assert.isFalse(after.fieldLocked, "ordinary movement must leave the field available")
    Assert.isTrue(after.tick > tickBefore, "settling movement must advance semantic ticks")

    game:moveTo({ fieldX = 684, fieldZ = 394 })
    game:step({ direction = "north" })
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, LAB_1F, "the existing door route must compose")
    Assert.equal(transition.destination.transition.phase, "idle")
  end)
end

return T
