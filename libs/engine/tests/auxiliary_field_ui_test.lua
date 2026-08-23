-- Logical auxiliary field UI tests pin the distinct HGSS hide/show timing
-- rules without requiring a rendered auxiliary display.

local Assert = require("tests.support.Assert")
local AuxiliaryFieldUi = require("libs.engine.src.AuxiliaryFieldUi")
local Errors = require("libs.errors.src.Errors")
local AuxiliaryUiTask = require("libs.engine.src.script.tasks.AuxiliaryUiTask")

local T = {}

function T.hide_already_hidden_completes_immediately()
  local ui = AuxiliaryFieldUi.new()
  Assert.isTrue(ui:requestVisible(false))
  ui:advance()

  Assert.isFalse(ui:requestVisible(false))
  Assert.deepEqual(ui:status(), { requested = "hidden", state = "hidden" })
end

function T.hide_waits_for_the_next_fixed_transition()
  local ui = AuxiliaryFieldUi.new()

  Assert.isTrue(ui:requestVisible(false))
  Assert.deepEqual(ui:status(), { requested = "hidden", state = "hiding" })
  ui:advance()
  Assert.deepEqual(ui:status(), { requested = "hidden", state = "hidden" })
end

function T.show_is_asynchronous_even_when_already_shown()
  local ui = AuxiliaryFieldUi.new()

  Assert.isTrue(ui:requestVisible(true))
  Assert.deepEqual(ui:status(), { requested = "shown", state = "showing" })
  ui:advance()
  Assert.deepEqual(ui:status(), { requested = "shown", state = "shown" })
end

function T.restored_wait_reissues_its_visibility_request()
  local ui = AuxiliaryFieldUi.new()

  local result = AuxiliaryUiTask.poll({ visible = false }, { services = { auxiliaryUi = ui } })

  Assert.isFalse(result.complete)
  Assert.deepEqual(ui:status(), { requested = "hidden", state = "hiding" })
end

function T.capture_and_restore_preserve_an_in_flight_transition()
  local ui = AuxiliaryFieldUi.new()
  ui:requestVisible(false)

  local restored = AuxiliaryFieldUi.restore(ui:capture())

  Assert.deepEqual(restored:status(), { requested = "hidden", state = "hiding" })
end

function T.validate_accepts_valid_directions_and_rejects_contradictions()
  local valid = {
    { requested = "shown", state = "shown" },
    { requested = "shown", state = "showing" },
    { requested = "hidden", state = "hidden" },
    { requested = "hidden", state = "hiding" },
  }
  for _, record in ipairs(valid) do
    Assert.notNil(AuxiliaryFieldUi.validate(record))
  end
  local invalid, err = AuxiliaryFieldUi.validate({ requested = "hidden", state = "showing" })
  Assert.isNil(invalid)
  Assert.isTrue(Errors.is(err))
end

function T.auxiliary_ui_task_validation_returns_a_structured_error_for_invalid_saved_state()
  local err = AuxiliaryUiTask.validate({ visible = "hidden" })
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
end

return { tests = T }
