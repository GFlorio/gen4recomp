-- Hook behaviour beyond the suite-execution contract: a setup that skips owns
-- the whole suite's precondition, and a cleanup that fails is a reported
-- failure rather than a swallowed error.

local Assert = require("tests.support.Assert")
local Execution = require("tests.runner.Execution")
local Suite = require("tests.runner.Suite")

local T = {}

local function runSuite(mod, options)
  local suite = Suite.normalize(mod, "fake.rom.alpha_test", "rom")
  return Execution.runSuite(suite, options or { capabilities = {} })
end

local function statuses(results)
  local out = {}
  for _, entry in ipairs(results) do
    out[#out + 1] = entry.test .. "=" .. entry.status
  end
  table.sort(out)
  return out
end

function T.setup_skip_skips_every_test_of_the_suite()
  local executed = false
  local results = runSuite({
    beforeAll = function(context)
      context:skip("no ready user-owned HGSS dump")
    end,
    tests = {
      ["a"] = function()
        executed = true
      end,
      ["b"] = function()
        executed = true
      end,
    },
  })

  Assert.isFalse(executed, "a skipped setup must not run test bodies")
  Assert.deepEqual(statuses(results), { "a=skip", "b=skip" })
  Assert.equal(results[1].message, "no ready user-owned HGSS dump")
end

function T.cleanup_failure_is_reported_without_hiding_test_results()
  local results = runSuite({
    afterAll = function()
      error("release failed", 0)
    end,
    tests = { ["a"] = function() end },
  })

  Assert.deepEqual(statuses(results), { "<afterAll>=fail", "a=pass" })
  local cleanup = results[2]
  Assert.isTrue(
    tostring(cleanup.message):find("release failed", 1, true) ~= nil,
    "cleanup failure keeps its message: " .. tostring(cleanup.message)
  )
end

-- A filter that excludes every test of a suite must not run its hooks either:
-- setup may acquire expensive resources nothing is going to use.
function T.filtered_out_suite_runs_no_hooks()
  local hooks = 0
  local results = runSuite({
    beforeAll = function()
      hooks = hooks + 1
    end,
    afterAll = function()
      hooks = hooks + 1
    end,
    tests = { ["a"] = function() end },
  }, { capabilities = {}, filter = "no such test" })

  Assert.equal(#results, 0)
  Assert.equal(hooks, 0)
end

return { tests = T }
