-- The script executor consumes game meaning through a small injected
-- evaluator. This test deliberately supplies synthetic semantics so the core
-- runtime can execute without constructing an HGSS field.

local Assert = require("tests.support.Assert")
local Runtime = require("libs.script.src.Runtime")

local T = {
  tests = {},
}

function T.tests.core_runtime_uses_injected_semantics()
  local vars = {}
  local frame = { nodeId = "entry", args = {} }
  local instance = {
    scriptId = "test.synthetic",
    instanceId = "instance-1",
    mode = "foreground",
    locals = {},
    textArgs = {},
    topFrame = function()
      return frame
    end,
  }
  local world = {
    getVar = function(_, id)
      return vars[id] or 0
    end,
    setVar = function(_, id, value)
      vars[id] = value
    end,
    isFlagSet = function()
      return false
    end,
  }
  local semantics = {}
  function semantics.evaluateValue(value)
    if type(value) == "table" and value.value == "var" then
      return vars[value.id] or 0
    end
    return value
  end
  function semantics.resolveIdOperand(value)
    return type(value) == "table" and value.value == "var" and value.id or value
  end
  function semantics.evaluateCondition(condition)
    return semantics.evaluateValue(condition.left) == semantics.evaluateValue(condition.right)
  end
  function semantics.writeRef(ref, value)
    instance.locals[ref.name] = value
  end

  local run = {
    instance = instance,
    environment = {
      acquireLock = function() end,
      releaseLock = function() end,
    },
    services = { world = world },
    semantics = semantics,
  }

  Assert.equal(
    Runtime.executeNode({
      op = "set_var",
      variable = { value = "var", id = "counter" },
      value = 7,
    }, run),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(vars.counter, 7)

  local branch = {
    op = "if",
    condition = {
      condition = "compare",
      left = { value = "var", id = "counter" },
      right = 7,
      operator = "eq",
    },
    yes = "matched",
    no = "missed",
  }
  Assert.equal(Runtime.executeNode(branch, run), Runtime.OUTCOME_CONTINUE)
  Assert.equal(frame.nodeId, "matched")
end

return T
