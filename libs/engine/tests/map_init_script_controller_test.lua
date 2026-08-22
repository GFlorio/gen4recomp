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

function T.unsupported_lifecycle_is_rejected_when_rules_are_bound()
  local ok, err = pcall(function()
    Controller.new({
      rules = { { type = "on_resume", scriptId = "resume" } },
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
  Assert.equal(err.context.type, "on_resume")
  Assert.equal(err.context.scriptId, "resume")
  Assert.equal(err.context.mapId, 63)
end

return { tests = T }
