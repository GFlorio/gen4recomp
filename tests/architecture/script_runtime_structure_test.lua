-- Static architecture contract for script evaluation ownership and named
-- behavior. These are source-shape invariants because the production lint and
-- code-health tools consume the same repository sources.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "architecture", "script", "runtime" },
  },
  tests = {},
}

local BASE = love.filesystem.getSourceBaseDirectory()

local VALUE_FUNCTIONS = {
  "writeRef",
  "evaluateValue",
  "resolveIdOperand",
  "evaluateMessage",
  "evaluateCondition",
  "resolveActor",
  "requireActor",
  "actorExists",
}

local VALUE_CONSUMERS = {
  "libs/engine/src/script/tasks/WarpTask.lua",
  "libs/engine/src/script/tasks/SoundWaitTask.lua",
  "libs/engine/src/script/tasks/MovementBarrierTask.lua",
}

local function readSource(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local source = handle:read("*a")
  handle:close()
  return source
end

local function hasLiteralRequire(source, moduleName)
  return source:find('require%s*%(%s*"' .. moduleName:gsub("%.", "%%.") .. '"%s*%)') ~= nil
end

local function hasStoredHandler(source)
  for line in source:gmatch("[^\n]*") do
    if line:find("HANDLERS", 1, true) and line:match("=%s*function") then
      return true
    end
  end
  return false
end

function T.tests.script_runtime_has_separate_named_value_ownership()
  local runtimeValuesPath = "libs/engine/src/script/RuntimeValues.lua"
  local runtimeValuesHandle = io.open(BASE .. "/" .. runtimeValuesPath, "r")
  Assert.notNil(runtimeValuesHandle, "script value and reference evaluation must have a dedicated RuntimeValues owner")
  if runtimeValuesHandle == nil then
    return
  end
  runtimeValuesHandle:close()

  local runtimeValues = require("libs.engine.src.script.RuntimeValues")
  for _, name in ipairs(VALUE_FUNCTIONS) do
    Assert.equal(type(runtimeValues[name]), "function", "RuntimeValues must own " .. name)
  end

  local Runtime = require("libs.engine.src.script.Runtime")
  for _, name in ipairs(VALUE_FUNCTIONS) do
    Assert.isNil(Runtime[name], "Runtime must not re-export " .. name)
  end

  local runtimeSource = readSource("libs/engine/src/script/Runtime.lua")
  Assert.isFalse(hasStoredHandler(runtimeSource), "runtime handlers must store named function references")
  Assert.isNil(runtimeSource:match("return%s+function"), "runtime must not return anonymous stored handlers")
  for _, name in ipairs(VALUE_FUNCTIONS) do
    Assert.isNil(runtimeSource:match("Runtime%." .. name), "runtime must call RuntimeValues for " .. name)
  end

  for _, path in ipairs(VALUE_CONSUMERS) do
    local source = readSource(path)
    Assert.isTrue(
      hasLiteralRequire(source, "libs.engine.src.script.RuntimeValues"),
      path .. " must depend on RuntimeValues for evaluation"
    )
    Assert.isFalse(
      hasLiteralRequire(source, "libs.engine.src.script.Runtime"),
      path .. " must not depend on the node interpreter for evaluation"
    )
  end

  local validatorSource = readSource("libs/engine/src/script/Validator.lua")
  Assert.isNil(validatorSource:match("CHECKERS[^\n]*=%s*function"), "validator checkers must be named references")

  local compilerSource = readSource("libs/engine/src/script/Compiler.lua")
  for _, name in ipairs({ "normalizeStep", "normalizeByType", "compileSteps" }) do
    Assert.isNil(
      compilerSource:match(name .. "%s*=%s*function"),
      "compiler helper " .. name .. " must be a named declaration"
    )
  end
end

return T
