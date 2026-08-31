-- Generic weather operation tests keep the weather ID opaque to libs.script.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Runtime = require("libs.script.src.Runtime")
local Compiler = require("libs.script.src.Compiler")
local S = require("gen4.script")

local T = {}

local function runWith(service)
  return {
    instance = { scriptId = "test.weather" },
    services = { weather = service },
  }
end

function T.dsl_and_compiler_accept_an_integer_weather_id()
  local step = S.changeWeather({ weatherId = 37 })
  Assert.deepEqual(step, { op = "change_weather", weatherId = 37 })
  local graph = assert(Compiler.compile(S.script({ api = 1, id = "test.weather", steps = { step } })))
  Assert.equal(graph.nodes[graph.entry].weatherId, 37)
end

function T.compiler_rejects_noninteger_and_extra_weather_fields()
  local _, noninteger = Compiler.compile(S.script({
    api = 1,
    id = "test.weather.noninteger",
    steps = { { op = "change_weather", weatherId = 1.5 } },
  }))
  Assert.isTrue(Errors.is(noninteger))

  local _, extra = Compiler.compile(S.script({
    api = 1,
    id = "test.weather.extra",
    steps = { { op = "change_weather", weatherId = 1, fog = true } },
  }))
  Assert.isTrue(Errors.is(extra))
end

function T.runtime_forwards_the_opaque_id_and_continues()
  local received
  local service = {
    change = function(_, weatherId)
      received = weatherId
    end,
  }
  Assert.equal(
    Runtime.executeNode({ op = "change_weather", weatherId = 37 }, runWith(service)),
    Runtime.OUTCOME_CONTINUE
  )
  Assert.equal(received, 37)
end

function T.runtime_reports_a_missing_weather_service()
  local ok, err = pcall(function()
    Runtime.executeNode({ op = "change_weather", weatherId = 12 }, runWith(nil))
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
