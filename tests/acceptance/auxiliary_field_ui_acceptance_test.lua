-- Production-composed auxiliary-field-UI contracts. The scripts are selected
-- from the real HeartGold cache and run through FieldRuntime; the harness
-- stops before drawing, so this also proves the logical state needs no HUD.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "auxiliary-ui" },
  },
  tests = {},
}

local HIDE_SCRIPT = "common.pokemart"
local SHOW_SCRIPT = "common.pokemart_cancel"

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

-- D10-AUX-01: a real Pokémart entry begins with opcode 746. The script must
-- retain field ownership while an actual hide request is incomplete, even in
-- the harness's no-HUD presentation mode.
function T.tests.hide_from_a_real_script_waits_for_the_logical_hidden_state()
  withGame(function(game)
    local started = game:startScript(HIDE_SCRIPT)
    Assert.isTrue(started.fieldLocked)
    Assert.deepEqual(game:auxiliaryUiStatus(), { requested = "hidden", state = "hiding" })
    local hidden = game:advanceUntil("auxiliary UI becomes hidden", function()
      return game:auxiliaryUiStatus().state == "hidden"
    end, 120)
    Assert.isTrue(hidden.fieldLocked)
  end)
end

-- D10-AUX-02: the matching real cancellation branch begins with opcode 747.
-- It must create an asynchronous boundary even when the logical UI begins
-- shown and no renderer/HUD has been installed.
function T.tests.show_from_a_real_script_synchronizes_asynchronously_without_a_hud()
  withGame(function(game)
    local started = game:startScript(SHOW_SCRIPT)
    Assert.isTrue(started.fieldLocked)
    Assert.deepEqual(game:auxiliaryUiStatus(), { requested = "shown", state = "showing" })
    local shown = game:advanceUntil("auxiliary UI becomes shown", function(snapshot)
      return game:auxiliaryUiStatus().state == "shown" and not snapshot.fieldLocked
    end, 120)
    Assert.isFalse(shown.fieldLocked)
  end)
end

-- Once opcode 746 has completed, its hidden result remains a logical field
-- fact. A fresh AuxiliaryFieldUi service on resumed boot must
-- not briefly restore the default shown state after the task has gone away.
function T.tests.restart_preserves_completed_hidden_auxiliary_ui_state()
  withGame(function(game)
    game:startScript(HIDE_SCRIPT)
    game:advanceUntil("auxiliary UI becomes hidden", function()
      return game:auxiliaryUiStatus().state == "hidden"
    end, 120)

    local resumed = game:restart({ save = "resume" })
    Assert.deepEqual(resumed:auxiliaryUiStatus(), { requested = "hidden", state = "hidden" })
  end)
end

-- D4-AUX-01: The visibility transition itself is part of deterministic script
-- continuation. Restarting immediately after opcode 746 must retain the
-- hiding state rather than reinitializing its newly-created service to shown.
-- The resumed task must then complete on the same two semantic fixed-update
-- boundaries as the original flow: one update finishes the transition, and a
-- second observes completion and releases the foreground script.
function T.tests.restart_resumes_an_in_flight_auxiliary_ui_hide_transition()
  withGame(function(game)
    game:startScript(HIDE_SCRIPT)
    Assert.deepEqual(game:auxiliaryUiStatus(), { requested = "hidden", state = "hiding" })

    local resumed = game:restart({ save = "resume" })
    Assert.deepEqual(resumed:auxiliaryUiStatus(), { requested = "hidden", state = "hiding" })
    Assert.isTrue(resumed:step().fieldLocked)
    Assert.deepEqual(resumed:auxiliaryUiStatus(), { requested = "hidden", state = "hidden" })
    Assert.isFalse(resumed:step().fieldLocked)
  end)
end

return T
