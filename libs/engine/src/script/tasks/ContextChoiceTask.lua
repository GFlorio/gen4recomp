-- Waits for the distinct HGSS GetMenuChoice provider. It owns opening and
-- closing the provider exactly once and returns its vanilla two-choice value.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local ContextChoiceTask = {}

local SELECTION_BY_DIRECTION = { up = 0, left = 0, down = 1, right = 1 }

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
  local events = (ctx.input or {}).uiEvents or {}
  assert(type(events) == "table", "context_choice UI events must be a table")
  for _, event in ipairs(events) do
    assert(type(event) == "table" and type(event.type) == "string", "context_choice UI event is invalid")
    if event.type == "navigate" then
      local selected = SELECTION_BY_DIRECTION[event.direction]
      if selected ~= nil then
        state.selected = choice:select(selected)
      end
    elseif event.type == "cancel" then
      choice:close()
      state.active = false
      return { complete = true, state = state, result = 1 }
    elseif event.type == "confirm" then
      local result = choice:confirm()
      choice:close()
      state.active = false
      return { complete = true, state = state, result = result }
    elseif
      event.type ~= "pointer_down"
      and event.type ~= "pointer_move"
      and event.type ~= "pointer_up"
      and event.type ~= "pointer_scroll"
    then
      assert(false, "unknown context_choice UI event " .. event.type)
    end
  end
  return { complete = false, state = state }
end

function ContextChoiceTask.cancel(state, _, ctx)
  if state.active and ctx ~= nil then
    local choice = provider(ctx)
    if choice:status() ~= nil then
      choice:close()
    end
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
