local Assert = require("tests.support.Assert")
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

return { tests = T }
