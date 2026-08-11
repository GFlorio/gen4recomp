-- Production-composed contracts for the raw HGSS GetMenuChoice command. The
-- real starter script reaches opcode 748 through the normal cache, override,
-- script scheduler, and field runtime path; rendering remains trapped.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "context-choice", "hgss" },
  },
  tests = {},
}

local STARTER_SCRIPT = "vanilla.hgss.scr_seq.0843.script_012"

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
  return game:advanceUntil("GetMenuChoice opens its contextual provider", function(snapshot)
    if game:contextChoiceStatus() ~= nil then
      return true
    end
    if snapshot.dialogue.modal then
      game:pressAction()
    end
    return false
  end, 240)
end

-- After the real starter confirmation message, opcode 748 must
-- block the foreground script on its own contextual provider. It is not a
-- MenuExec reconstruction and it must not be replaced by a placeholder
-- dialogue. This scenario establishes the production boundary that every
-- classified provider must cross.
function T.tests.real_get_menu_choice_opens_a_contextual_provider()
  withGame(function(game)
    local started = game:startScript(STARTER_SCRIPT)
    Assert.isTrue(started.fieldLocked)

    local active = advanceToContextChoice(game)
    Assert.isTrue(active.fieldLocked)

    local choice = game:contextChoiceStatus()
    Assert.isTrue(type(choice) == "table", "GetMenuChoice must expose an active contextual provider")
    Assert.equal(choice.state, "active")
  end)
end

-- Selection is script-visible state, not a disposable provider
-- detail. Restarting the real foreground GetMenuChoice flow must reconstruct
-- the waiting provider with the selected vanilla result intact, and the
-- restored provider must accept confirmation without a replacement direction
-- edge.
function T.tests.restart_preserves_and_confirms_the_selected_contextual_choice()
  withGame(function(game)
    advanceToContextChoice(game)
    game:move("east")
    Assert.equal(game:contextChoiceStatus().selected, 1)

    local resumed = game:restart({ save = "resume" })
    Assert.deepEqual(resumed:contextChoiceStatus(), { state = "active", selected = 1 })
    resumed:pressAction()
    Assert.isNil(resumed:contextChoiceStatus())
  end)
end

return T
