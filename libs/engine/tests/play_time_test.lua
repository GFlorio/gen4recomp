-- PlayTime owns elapsed in-game seconds after playable field entry. It never
-- consults civil time, includes modal time while active, and saturates at the
-- retail display limit.

local Assert = require("tests.support.Assert")
local PlayTime = require("libs.engine.src.PlayTime")

local T = {}

function T.inactive_time_is_excluded_and_active_time_is_whole_seconds()
  local playTime = PlayTime.new()
  playTime:advance(12.9)
  Assert.equal(playTime:seconds(), 0)
  playTime:start()
  playTime:advance(12.9, { modal = "trainer-card" })
  Assert.equal(playTime:seconds(), 12)
  playTime:stop()
  playTime:advance(10)
  Assert.equal(playTime:seconds(), 12)
end

function T.large_updates_saturate_without_wrapping()
  local playTime = PlayTime.new(PlayTime.MAX_SECONDS - 1)
  playTime:start()
  playTime:advance(1000000)
  Assert.equal(playTime:seconds(), PlayTime.MAX_SECONDS)
  Assert.throws(function()
    PlayTime.new(PlayTime.MAX_SECONDS + 1)
  end)
end

return { tests = T }
