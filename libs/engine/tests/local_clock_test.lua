-- LocalClock is the validated host-local civil-time boundary. Consumers get
-- independent snapshots, while malformed calendar fields fail at injection.

local Assert = require("tests.support.Assert")
local LocalClock = require("libs.engine.src.LocalClock")

local T = {}

function T.samples_are_copied_and_provider_is_called_each_time()
  local current = { year = 2024, month = 2, day = 29, hour = 23, minute = 59, second = 58 }
  local calls = 0
  local clock = LocalClock.new(function()
    calls = calls + 1
    return current
  end)

  local first = clock:nowLocal()
  current.hour = 0
  Assert.equal(first.hour, 23, "a consumer cannot observe a later provider mutation")
  Assert.equal(clock:nowLocal().hour, 0)
  Assert.equal(calls, 2)
end

function T.invalid_civil_dates_are_rejected()
  for _, value in ipairs({
    { year = 2023, month = 2, day = 29, hour = 0, minute = 0, second = 0 },
    { year = 2024, month = 4, day = 31, hour = 0, minute = 0, second = 0 },
    { year = 2024, month = 1, day = 1, hour = 24, minute = 0, second = 0 },
  }) do
    Assert.throws(function()
      LocalClock.new(function()
        return value
      end):nowLocal()
    end)
  end
end

return { tests = T }
