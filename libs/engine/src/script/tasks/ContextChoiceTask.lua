-- Waits for the distinct HGSS GetMenuChoice provider. It owns opening and
-- closing the provider exactly once and returns its vanilla two-choice value.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local ContextChoiceTask = {}

ContextChoiceTask.type = "context_choice"
ContextChoiceTask.version = 1

local function provider(ctx)
  local choice = assert(ctx.services.contextChoice, "context_choice requires a context choice provider")
  assert(
    type(choice.open) == "function"
      and type(choice.close) == "function"
      and type(choice.status) == "function"
      and type(choice.select) == "function"
      and type(choice.confirm) == "function",
    "context choice provider is invalid"
  )
  return choice
end

function ContextChoiceTask.create(_, ctx)
  provider(ctx)
  return { active = false, phase = "opening", selected = 0 }
end

function ContextChoiceTask.poll(state, ctx)
  local choice = provider(ctx)
  if state.phase == "opening" then
    choice:open(state.selected)
    state.active = true
    state.phase = "waiting"
    return { complete = false, state = state }
  end
  if choice:status() == nil then
    choice:open(state.selected)
  end
  local input = ctx.input or {}
  if input.pressedDirection ~= nil then
    state.selected = choice:select(input.pressedDirection)
  end
  if input.pressedCancel then
    choice:close()
    state.active = false
    return { complete = true, state = state, result = 1 }
  end
  if input.pressedAction then
    local result = choice:confirm()
    choice:close()
    state.active = false
    return { complete = true, state = state, result = result }
  end
  return { complete = false, state = state }
end

function ContextChoiceTask.cancel(state, _, ctx)
  if state.active and ctx ~= nil then
    provider(ctx):close()
  end
  state.active = false
end

function ContextChoiceTask.validate(state)
  if type(state) ~= "table" or type(state.active) ~= "boolean" or (state.selected ~= 0 and state.selected ~= 1) then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "context_choice task state is invalid",
      { state = state }
    )
  end
  if state.phase ~= "opening" and state.phase ~= "waiting" then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "context_choice task phase is invalid",
      { state = state }
    )
  end
  if (state.phase == "opening") ~= not state.active then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "context_choice task active state does not match its phase",
      { state = state }
    )
  end
  return nil
end

return ContextChoiceTask
