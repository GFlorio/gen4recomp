local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Controller = require("libs.engine.src.MapInitScriptController")

local T = {}

function T.first_matching_rule_claims_once_and_rechecks_after_world_change()
  local value = 3
  local starts = {}
  ---@type MapInitScriptController
  local controller = Controller.new({
    rules = {
      {
        type = "on_frame_eq",
        rules = {
          { variableId = 10, equals = 3, scriptId = "first" },
          { variableId = 10, equals = 3, scriptId = "second" },
        },
      },
    },
    world = {
      getVar = function()
        return value
      end,
    },
    scriptClient = {
      startInitScript = function(_, id, tick)
        starts[#starts + 1] = { id = id, tick = tick }
        return #starts == 1
      end,
    },
  })

  Assert.isTrue(controller:evaluate(1))
  Assert.deepEqual(starts, { { id = "first", tick = 1 } })
  value = 0
  Assert.isFalse(controller:evaluate(2))
  Assert.equal(#starts, 1)
end

function T.mixed_lifecycles_bind_and_dispatch_first_matching_event()
  local starts = {}
  local controller = Controller.new({
    rules = {
      { type = "on_transition", scriptId = "transition" },
      { type = "on_resume", scriptId = "resume" },
      { type = "on_frame_eq", rules = { { variableId = 10, equals = 3, scriptId = "frame" } } },
      { type = "on_load", scriptId = "load" },
    },
    mapId = 63,
    world = {
      getVar = function()
        return 3
      end,
    },
    scriptClient = {
      startInitScript = function(_, id, tick)
        starts[#starts + 1] = { id = id, tick = tick }
        return true
      end,
    },
  })

  Assert.isTrue(controller:startLifecycle("on_load", 4))
  Assert.isTrue(controller:startLifecycle("on_transition", 3))
  Assert.deepEqual(starts, {
    { id = "load", tick = 4 },
    { id = "transition", tick = 3 },
  })
  Assert.isTrue(controller:startLifecycle("on_resume", 5))
  Assert.isTrue(controller:evaluateFrame(6))
  Assert.deepEqual(starts, {
    { id = "load", tick = 4 },
    { id = "transition", tick = 3 },
    { id = "resume", tick = 5 },
    { id = "frame", tick = 6 },
  })
end

function T.lifecycle_presence_distinguishes_absent_from_blocked_start()
  local attempts = 0
  local controller = Controller.new({
    rules = { { type = "on_transition", scriptId = "transition" } },
    world = {
      getVar = function()
        return 0
      end,
    },
    scriptClient = {
      startInitScript = function()
        attempts = attempts + 1
        return false
      end,
    },
  })

  Assert.isTrue(controller:hasLifecycle("on_transition"))
  Assert.isFalse(controller:hasLifecycle("on_load"))
  Assert.isFalse(controller:startLifecycle("on_transition", 1))
  Assert.equal(attempts, 1)
end

function T.unknown_lifecycle_is_rejected_with_context()
  local ok, err = pcall(function()
    Controller.new({
      rules = { { type = "on_unknown", scriptId = "bad" } },
      mapId = 63,
      world = {
        getVar = function()
          return 0
        end,
      },
      scriptClient = { startInitScript = function() end },
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  assert(err)
  Assert.equal(err.code, "MAP_INIT_UNSUPPORTED_LIFECYCLE")
  Assert.equal(err.context.type, "on_unknown")
  Assert.equal(err.context.mapId, 63)
end

function T.malformed_lifecycle_fields_are_rejected_with_context()
  local cases = {
    { rules = { { type = "on_load", scriptId = 0 } }, groupIndex = 1 },
    {
      rules = { { type = "on_frame_eq", rules = { { variableId = -1, equals = 0, scriptId = "bad" } } } },
      groupIndex = 1,
      ruleIndex = 1,
    },
  }
  for _, case in ipairs(cases) do
    local ok, err = pcall(function()
      Controller.new({
        rules = case.rules,
        mapId = 63,
        world = {
          getVar = function()
            return 0
          end,
        },
        scriptClient = { startInitScript = function() end },
      })
    end)
    Assert.isFalse(ok)
    Assert.isTrue(Errors.is(err))
    assert(err)
    Assert.equal(err.code, "MAP_INIT_UNSUPPORTED_LIFECYCLE")
    Assert.equal(err.context.mapId, 63)
    Assert.equal(err.context.groupIndex, case.groupIndex)
    Assert.equal(err.context.ruleIndex, case.ruleIndex)
  end
end

return { tests = T }
