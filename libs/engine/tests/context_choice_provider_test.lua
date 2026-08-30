-- ContextChoiceProvider tests cover the distinct two-result HGSS provider.

local Assert = require("tests.support.Assert")
local ContextChoiceProvider = require("libs.engine.src.ContextChoiceProvider")
local ContextChoiceTask = require("libs.hgss.src.script.tasks.ContextChoiceTask")

local T = {}

T["context choice keeps its active selection until the task closes it"] = function()
  local provider = ContextChoiceProvider.new()
  Assert.equal(provider:status(), nil)

  provider:open()
  Assert.deepEqual(provider:status(), { state = "active", selected = 0 })
  provider:select(1)
  Assert.equal(provider:confirm(), 1)
  provider:close()
  Assert.equal(provider:status(), nil)
end

T["context choice task releases an opened provider when cancelled"] = function()
  local provider = ContextChoiceProvider.new()
  local ctx = { services = { contextChoice = provider } }
  local state = ContextChoiceTask.create({}, ctx)
  ContextChoiceTask.poll(state, ctx)
  Assert.notNil(provider:status())

  ContextChoiceTask.cancel(state, "script cancelled", ctx)
  Assert.equal(provider:status(), nil)
end

T["context choice task consumes normalized UI navigation and confirmation"] = function()
  local provider = ContextChoiceProvider.new()
  local ctx = { services = { contextChoice = provider }, input = {} }
  local state = ContextChoiceTask.create({}, ctx)
  ContextChoiceTask.poll(state, ctx)

  ctx.input = { uiEvents = { { type = "navigate", direction = "right" } } }
  local waiting = ContextChoiceTask.poll(state, ctx)
  Assert.isFalse(waiting.complete)
  Assert.equal(provider:status().selected, 1)

  ctx.input = { uiEvents = { { type = "confirm" } } }
  local completed = ContextChoiceTask.poll(state, ctx)
  Assert.isTrue(completed.complete)
  Assert.equal(completed.result, 1)
  Assert.equal(provider:status(), nil)
end

T["context choice task ignores pointer UI events"] = function()
  local provider = ContextChoiceProvider.new()
  local ctx = { services = { contextChoice = provider }, input = {} }
  local state = ContextChoiceTask.create({}, ctx)
  ContextChoiceTask.poll(state, ctx)

  ctx.input = {
    uiEvents = {
      { type = "pointer_down", x = 2, y = 3 },
      { type = "pointer_move", x = 4, y = 5 },
      { type = "pointer_scroll", dy = 1 },
      { type = "pointer_up", x = 4, y = 5 },
    },
  }
  local waiting = ContextChoiceTask.poll(state, ctx)

  Assert.isFalse(waiting.complete)
  Assert.equal(provider:status().selected, 0)
end

T["context choice task restores its selected value into a fresh provider"] = function()
  local provider = ContextChoiceProvider.new()
  local ctx = { services = { contextChoice = provider }, input = {} }
  local state = ContextChoiceTask.create({}, ctx)
  ContextChoiceTask.poll(state, ctx)
  ctx.input = { uiEvents = { { type = "navigate", direction = "right" } } }
  ContextChoiceTask.poll(state, ctx)

  Assert.equal(state.selected, 1)

  local restoredProvider = ContextChoiceProvider.new()
  local restored = ContextChoiceTask.poll(state, { services = { contextChoice = restoredProvider }, input = {} })
  Assert.isFalse(restored.complete)
  Assert.deepEqual(restoredProvider:status(), { state = "active", selected = 1 })
end

T["context choice task cancellation tolerates an unmaterialized restored provider"] = function()
  local state = { active = true, phase = "waiting", selected = 1 }
  local provider = ContextChoiceProvider.new()

  ContextChoiceTask.cancel(state, "script cancelled", { services = { contextChoice = provider } })

  Assert.isFalse(state.active)
  Assert.equal(provider:status(), nil)
end

return { tests = T }
