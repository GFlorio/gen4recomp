-- PosePerformanceCounter: the pose/material evaluation counters of the
-- animation runtime (spec section 39). Rows keyed by arbitrary keys (the
-- scene loader keys by ModelInstance) accumulate seconds and call counts per
-- phase; per-phase totals give the per-scene view. The clock is injectable
-- so the timing math is deterministic under test. Also covers the ModelInstance
-- instrumentation: an instance constructed with `opts.performance` records its
-- pose and material evaluations into the shared counter.

local Assert = require("tests.support.Assert")
local PosePerformanceCounter = require("libs.engine.src.PosePerformanceCounter")
local ModelInstance = require("libs.engine.src.ModelInstance")
local GenericModelFixture = require("tests.support.GenericModelFixture")

local T = {}

-- A clock returning the given values in order, then the last one forever.
local function fakeClock(sequence)
  local i = 0
  return function()
    i = i + 1
    return sequence[math.min(i, #sequence)]
  end
end

function T.record_accumulates_counts_and_seconds_per_phase()
  local counter = PosePerformanceCounter.new({ clock = fakeClock({ 0, 1, 2 }) })
  counter:record("door", PosePerformanceCounter.POSE, 1.5)
  counter:record("door", PosePerformanceCounter.POSE, 2.5)
  counter:record("door", PosePerformanceCounter.MATERIAL, 0.5)
  counter:record("sky", PosePerformanceCounter.POSE, 3)
  Assert.equal(counter:count("door", PosePerformanceCounter.POSE), 2)
  Assert.equal(counter:seconds("door", PosePerformanceCounter.POSE), 4)
  Assert.equal(counter:count("door", PosePerformanceCounter.MATERIAL), 1)
  Assert.equal(counter:seconds("door", PosePerformanceCounter.MATERIAL), 0.5)
  Assert.equal(counter:count("sky", PosePerformanceCounter.POSE), 1)
  -- Totals aggregate over every key: the per-scene view.
  Assert.equal(counter:count(nil, PosePerformanceCounter.POSE), 3)
  Assert.equal(counter:seconds(nil, PosePerformanceCounter.POSE), 7)
  -- Unrecorded phases read zero.
  Assert.equal(counter:count(nil, PosePerformanceCounter.SYNC), 0)
  Assert.equal(counter:count("door", PosePerformanceCounter.UPDATE), 0)
end

function T.unknown_phase_raises()
  local counter = PosePerformanceCounter.new()
  local ok, err = pcall(function()
    counter:record("m", "bogus", 1)
  end)
  Assert.isFalse(ok, "unknown phase must raise")
  Assert.isTrue(tostring(err):find("phase", 1, true) ~= nil, "error names the phase")
end

function T.negative_seconds_raise()
  local counter = PosePerformanceCounter.new()
  local ok = pcall(function()
    counter:record("m", PosePerformanceCounter.POSE, -1)
  end)
  Assert.isFalse(ok, "negative elapsed time must raise")
end

function T.measure_times_the_call_and_returns_its_result()
  local counter = PosePerformanceCounter.new({ clock = fakeClock({ 0, 5 }) })
  local value = counter:measure("door", PosePerformanceCounter.POSE, function()
    return 42
  end)
  Assert.equal(value, 42)
  Assert.equal(counter:count("door", PosePerformanceCounter.POSE), 1)
  Assert.equal(counter:seconds("door", PosePerformanceCounter.POSE), 5)
end

function T.measure_propagates_the_calls_errors()
  local counter = PosePerformanceCounter.new({ clock = fakeClock({ 0, 5 }) })
  local ok = pcall(function()
    counter:measure("door", PosePerformanceCounter.POSE, function()
      error("boom")
    end)
  end)
  Assert.isFalse(ok, "measure must not swallow the call's error")
  Assert.equal(counter:count("door", PosePerformanceCounter.POSE), 0)
end

function T.summary_is_sorted_by_key_then_phase()
  local counter = PosePerformanceCounter.new()
  counter:record("b", PosePerformanceCounter.POSE, 1)
  counter:record("a", PosePerformanceCounter.MATERIAL, 2)
  counter:record("a", PosePerformanceCounter.POSE, 3)
  local rows = counter:summary()
  Assert.equal(#rows, 3)
  Assert.equal(rows[1].key, "a")
  Assert.equal(rows[1].phase, "material")
  Assert.equal(rows[2].key, "a")
  Assert.equal(rows[2].phase, "pose")
  Assert.equal(rows[3].key, "b")
  Assert.equal(rows[3].phase, "pose")
  Assert.equal(rows[3].count, 1)
end

function T.summary_renders_keys_through_nameof()
  local counter = PosePerformanceCounter.new()
  local key = { id = "instance" }
  counter:record(key, PosePerformanceCounter.POSE, 1)
  local rows = counter:summary(function(k)
    return k.id
  end)
  Assert.equal(rows[1].key, "instance")
end

-- ---- ModelInstance instrumentation ----

function T.instance_records_pose_and_material_into_the_shared_counter()
  local def = GenericModelFixture.doorDefinition()
  local counter = PosePerformanceCounter.new()
  local instance = ModelInstance.new(def, { performance = counter })
  instance:play("door.open")
  instance:updateFixed()
  instance:evaluatePose()
  instance:evaluateMaterials()
  Assert.equal(counter:count(instance, PosePerformanceCounter.POSE), 1)
  Assert.equal(counter:count(instance, PosePerformanceCounter.MATERIAL), 1)
  Assert.isTrue(counter:seconds(instance, PosePerformanceCounter.POSE) >= 0)
  Assert.isTrue(counter:seconds(instance, PosePerformanceCounter.MATERIAL) >= 0)
  -- The scene totals aggregate the instance rows.
  Assert.equal(counter:count(nil, PosePerformanceCounter.POSE), 1)
  Assert.equal(counter:count(nil, PosePerformanceCounter.MATERIAL), 1)
end

function T.instances_without_a_performance_counter_are_unchanged()
  local def = GenericModelFixture.doorDefinition()
  local instance = ModelInstance.new(def)
  instance:play("door.open")
  local pose = instance:evaluatePose()
  Assert.notNil(pose)
  instance:evaluateMaterials()
  Assert.notNil(instance.poseState)
end

return T
