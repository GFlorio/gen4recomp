-- The GraphicsSmoke wrap must not swallow the runner's explicit skip: a
-- graphics body that calls `context:skip` must report a skip, not a failure.
-- The wrap runs bodies under its own xpcall, so the runner's table error
-- (the SKIP marker) has to pass through unchanged; a wrap that stringifies
-- it turns an honest skip into a red graphics suite.

local Assert = require("tests.support.Assert")
local Execution = require("tests.runner.Execution")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local Suite = require("tests.runner.Suite")

local T = {}

function T.a_graphics_body_skip_reports_a_skip()
  local suite = GraphicsSmoke.suite({
    ["a"] = function(scope, context)
      context:skip("no field-UI class in the shared derived cache")
    end,
  })
  local normalized = Suite.normalize(suite, "fake.graphics.skip_test", "graphics")
  local results = Execution.runSuite(normalized, { capabilities = { graphics = true } })

  Assert.equal(#results, 1)
  Assert.equal(results[1].status, "skip")
  Assert.equal(results[1].message, "no field-UI class in the shared derived cache")
end

return { tests = T }
