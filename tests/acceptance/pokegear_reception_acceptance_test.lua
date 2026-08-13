-- Production-composed contracts for the pokegear reception script
-- (scr_seq 843 script 13). With FLAG_GOT_STARTER set its supported branch
-- runs message -> 746 hide -> 748 choice -> 747 show through the real cache,
-- override, script scheduler, and field runtime path; the cancel selection
-- skips the unsupported HealParty node, so the vanilla 746/747/748 operations
-- are reachable through production composition. Rendering stays trapped.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "auxiliary-ui", "context-choice", "hgss" },
  },
  tests = {},
}

-- The pre-set flag id is FLAG_GOT_STARTER (libs/assets FieldScriptSymbols).
local POKEGEAR_SCRIPT = "vanilla.hgss.scr_seq.0843.script_013"
local STARTER_FLAG = 106

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function advanceToContextChoice(game)
  return game:advanceUntil("pokegear reception opens its contextual choice", function(snapshot)
    if game:contextChoiceStatus() ~= nil then
      return true
    end
    if snapshot.dialogue.modal then
      game:pressAction()
    end
    return false
  end, 240)
end

-- The full pokegear reception flow: opcode 746 hides the auxiliary UI before
-- the first contextual choice, opcode 748 opens the provider, confirming the
-- cancel branch reaches source opcode 747, and the real show operation then
-- completes, releasing field control.
function T.tests.pokegear_reception_runs_its_full_auxiliary_ui_and_choice_flow()
  withGame(function(game)
    game:setWorldState({ flag = STARTER_FLAG })
    game:startScript(POKEGEAR_SCRIPT)
    game:advanceUntil("pokegear reception opcode 746 requests auxiliary UI hide", function(snapshot)
      if game:auxiliaryUiStatus().requested == "hidden" then
        return true
      end
      if snapshot.dialogue.modal then
        game:pressAction()
      end
      return false
    end, 240)

    local active = advanceToContextChoice(game)
    Assert.isTrue(active.fieldLocked)
    Assert.equal(game:contextChoiceStatus().state, "active")

    game:move("east")
    Assert.equal(game:contextChoiceStatus().selected, 1)
    game:pressAction()
    game:advanceUntil("pokegear reception opcode 747 requests auxiliary UI show", function()
      return game:auxiliaryUiStatus().requested == "shown"
    end, 120)
    Assert.deepEqual(game:auxiliaryUiStatus(), { requested = "shown", state = "showing" })
    local completed = game:advanceUntil("pokegear reception completes releasing field control", function(snapshot)
      return game:auxiliaryUiStatus().state == "shown" and not snapshot.fieldLocked
    end, 120)
    Assert.isFalse(completed.fieldLocked)
  end)
end

-- Selection is script-visible state, not a disposable provider
-- detail. Restarting the real foreground GetMenuChoice flow must reconstruct
-- the waiting provider with the selected vanilla result intact, and the
-- restored provider must accept confirmation without a replacement direction
-- edge.
function T.tests.restart_preserves_and_confirms_the_selected_pokegear_choice()
  withGame(function(game)
    game:setWorldState({ flag = STARTER_FLAG })
    game:startScript(POKEGEAR_SCRIPT)
    advanceToContextChoice(game)
    game:move("east")
    Assert.equal(game:contextChoiceStatus().selected, 1)

    local resumed = game:restart({ save = "resume" })
    resumed:step()
    Assert.deepEqual(resumed:contextChoiceStatus(), { state = "active", selected = 1 })
    resumed:pressAction()
    Assert.isNil(resumed:contextChoiceStatus())
  end)
end

return T
