-- RuntimeAllocationProfiler: the cheap per-tick allocation counters of the
-- animation path (spec section 39). Call sites count the objects they create
-- per tick (pose states, draw items, player advances); beginTick/endTick fold
-- one tick's counts into the running totals while keeping the last tick
-- visible, so the per-frame allocation cost of the animated scene can be read
-- without any GC involvement. Pure domain module.

local Assert = require("tests.support.Assert")
local RuntimeAllocationProfiler = require("libs.engine.src.RuntimeAllocationProfiler")

local T = {}

function T.add_accumulates_within_a_tick()
  local profiler = RuntimeAllocationProfiler.new()
  profiler:beginTick()
  profiler:add("pose")
  profiler:add("items", 3)
  profiler:add("pose")
  profiler:endTick()
  Assert.equal(profiler:count("pose"), 2)
  Assert.equal(profiler:lastTick("pose"), 2)
  Assert.equal(profiler:count("items"), 3)
  Assert.equal(profiler:lastTick("items"), 3)
end

function T.totals_accumulate_across_ticks_while_last_tick_rolls()
  local profiler = RuntimeAllocationProfiler.new()
  profiler:beginTick()
  profiler:add("pose", 2)
  profiler:endTick()
  profiler:beginTick()
  profiler:add("pose")
  profiler:endTick()
  Assert.equal(profiler:count("pose"), 3)
  Assert.equal(profiler:lastTick("pose"), 1)
  Assert.equal(profiler:count("update"), 0)
end

function T.add_outside_a_tick_counts_immediately()
  local profiler = RuntimeAllocationProfiler.new()
  profiler:add("bandSwap")
  Assert.equal(profiler:count("bandSwap"), 1)
  Assert.equal(profiler:lastTick("bandSwap"), 0, "outside-tick counts are not part of any tick")
end

function T.begin_and_end_ticks_must_balance()
  local profiler = RuntimeAllocationProfiler.new()
  local nested = pcall(function()
    profiler:beginTick()
    profiler:beginTick()
  end)
  Assert.isFalse(nested, "a nested tick must raise")
  profiler:endTick() -- the first beginTick still holds the tick open
  local orphan = pcall(function()
    profiler:endTick()
  end)
  Assert.isFalse(orphan, "endTick without beginTick must raise")
end

function T.add_requires_a_positive_count()
  local profiler = RuntimeAllocationProfiler.new()
  local bad = pcall(function()
    profiler:add("pose", 0)
  end)
  Assert.isFalse(bad, "zero-count allocations must raise")
end

function T.report_is_sorted_by_site()
  local profiler = RuntimeAllocationProfiler.new()
  profiler:beginTick()
  profiler:add("items", 2)
  profiler:add("pose")
  profiler:endTick()
  local rows = profiler:report()
  Assert.equal(#rows, 2)
  Assert.equal(rows[1].site, "items")
  Assert.equal(rows[1].total, 2)
  Assert.equal(rows[1].last, 2)
  Assert.equal(rows[2].site, "pose")
  Assert.equal(rows[2].total, 1)
  Assert.equal(rows[2].last, 1)
end

return T
