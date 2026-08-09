-- starter_choice task implementation : the
-- example raw extension task owned by the starter-machine UI state. It is
-- serializable and proves the raw task save model: the selection index is
-- part of the task state, d-pad edges cycle the choices, the action edge
-- confirms (never in the same tick the task becomes eligible), and the
-- completed selection returns through the generic task result. The
-- surrounding script remains data. Pure domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local StarterChoiceTask = {}

StarterChoiceTask.type = "starter_choice"
StarterChoiceTask.version = 1

-- The three HGSS starters by national dex number (SPECIES_CYNDAQUIL,
-- SPECIES_TOTODILE, SPECIES_CHIKORITA).
StarterChoiceTask.DEFAULT_CHOICES = { 155, 158, 152 }

---@param spec table
---@param ctx table
---@return table state
function StarterChoiceTask.create(spec, ctx)
  local choices = spec.choices or StarterChoiceTask.DEFAULT_CHOICES
  if type(choices) ~= "table" or #choices == 0 then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "starter_choice requires a non-empty choice list",
      { scriptId = ctx.instance.scriptId }
    )
  end
  local selection = spec.selection or 1
  if selection < 1 or selection > #choices then
    selection = 1
  end
  return {
    choices = choices,
    selection = selection,
    phase = "choosing",
  }
end

---@param state table
---@param ctx table
---@return table
function StarterChoiceTask.poll(state, ctx)
  local input = ctx.input or {}
  local direction = input.pressedDirection
  if direction == "left" or direction == "west" then
    state.selection = state.selection - 1
    if state.selection < 1 then
      state.selection = #state.choices
    end
  elseif direction == "right" or direction == "east" then
    state.selection = state.selection + 1
    if state.selection > #state.choices then
      state.selection = 1
    end
  end
  if input.pressedAction then
    return {
      complete = true,
      state = state,
      result = { species = state.choices[state.selection], selection = state.selection },
    }
  end
  return { complete = false, state = state }
end

---@param state table
---@param reason string
function StarterChoiceTask.cancel(state, reason)
  state.cancelled = reason
end

---@param state table
---@return Errors.Error|nil
function StarterChoiceTask.validate(state)
  if type(state) ~= "table" or type(state.choices) ~= "table" or state.phase ~= "choosing" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "starter_choice state must hold its choices",
      { state = state }
    )
  end
  return nil
end

return StarterChoiceTask
