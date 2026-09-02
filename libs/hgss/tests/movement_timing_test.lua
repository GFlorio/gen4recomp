-- Source-backed movement lifetimes: independent timing evidence for the
-- semantic duration owner and its supported movement command families.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local MovementTask = require("libs.hgss.src.script.tasks.MovementTask")
---@cast MovementTask TaskImplementation
local MovementBarrierTask = require("libs.hgss.src.script.tasks.MovementBarrierTask")
---@cast MovementBarrierTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")
local MovementCalibration = require("libs.hgss.src.script.tasks.MovementCalibration")

local T = { tests = {} }

-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/unk_02062108.s: run commands 88-91 use a four-update movement countdown;
-- commands 24-39 store the configured count plus one for walk-in-place;
-- commands 44-59 use sixteen updates for slow/on-spot and far jumps and
-- eight updates for fast/on-spot and near jumps.
local SOURCE_TIMINGS = {
  { action = { action = "walk_in_place", speed = "slower" }, ticks = 33 },
  { action = { action = "walk_in_place", speed = "slow" }, ticks = 17 },
  { action = { action = "walk_in_place", speed = "normal" }, ticks = 9 },
  { action = { action = "walk_in_place", speed = "fast" }, ticks = 5 },
  { action = { action = "walk", speed = "run" }, ticks = 4 },
  { action = { action = "jump", distance = "zero", speed = "slow" }, ticks = 16 },
  { action = { action = "jump", distance = "zero", speed = "fast" }, ticks = 8 },
  { action = { action = "jump", distance = "near", speed = "fast" }, ticks = 8 },
  { action = { action = "jump", distance = "far", speed = "fast" }, ticks = 16 },
  -- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
  -- asm/overlay_01_022001E4.s: state 1 holds for 30 updates, surrounded
  -- by the entrance and completion-poll progression.
  { action = { action = "emote", name = "exclamation" }, ticks = 33 },
}

-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/unk_02062108.s and asm/unk_data_020FDB44.s: gesture lifetimes
-- are the per-update state-machine counts including same-update chaining
-- of setup/final steps via sub_02062400.
local GESTURE_TIMINGS = {
  { action = { action = "gesture", name = "warp_out" }, ticks = 20 },
  { action = { action = "gesture", name = "warp_in" }, ticks = 20 },
  { action = { action = "gesture", name = "nurse_bow" }, ticks = 10 },
  { action = { action = "gesture", name = "give" }, ticks = 22 },
  { action = { action = "gesture", name = "receive" }, ticks = 22 },
}

local function timingHarness()
  local services = FakeServices.new()
  services.audio = { play = function() end }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("movement", 1, MovementTask)
  taskRegistry:register("movement_barrier", 1, MovementBarrierTask)
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

local function timingScript(id)
  return S.script({ api = 1, id = id, steps = { S.waitTicks({ ticks = 100 }) } })
end

local function startTimingTask(h, action, tick)
  h.services.actors:add("elm", { fieldX = 4, fieldZ = 6, facing = "north" })
  local resource = timingScript("test.source_timing_" .. action.action)
  h.registry:installBase(resource.id, resource, "generated")
  local instance = h.scheduler:createForeground(assert(h.composition:effective(resource.id)), nil, tick)
  local taskId = h.scheduler:createTask(
    "movement",
    { actor = "elm", sequence = { action }, blocking = true },
    assert(h.scheduler:instance(instance)),
    tick,
    nil
  )
  return assert(h.scheduler:taskById(taskId))
end

function T.tests.source_timing_matrix_matches_the_runtime_duration_owner()
  for _, case in ipairs(SOURCE_TIMINGS) do
    Assert.equal(MovementCalibration.actionTicks(case.action), case.ticks, "source timing for " .. case.action.action)
  end
  for _, case in ipairs(GESTURE_TIMINGS) do
    Assert.equal(
      MovementCalibration.actionTicks(case.action),
      case.ticks,
      "source timing for gesture " .. case.action.name
    )
  end
end

function T.tests.jump_duration_rejects_an_unverified_distance_and_speed_pair()
  local ok, err = pcall(function()
    MovementCalibration.actionTicks({ action = "jump", distance = "near", speed = "slow" })
  end)
  Assert.isFalse(ok, "an unverified jump combination must fail")
  Assert.isTrue(tostring(err):find("unknown jump", 1, true) ~= nil, "failure identifies the jump lookup")
end

function T.tests.movement_task_holds_each_source_boundary_until_its_final_tick()
  local cases = {
    { name = "fast walk-in-place", action = { action = "walk_in_place", speed = "fast" }, ticks = 5 },
    { name = "run", action = { action = "walk", direction = "east", speed = "run" }, ticks = 4 },
    {
      name = "far fast jump",
      action = { action = "jump", direction = "east", distance = "far", speed = "fast" },
      ticks = 16,
    },
    { name = "exclamation", action = { action = "emote", name = "exclamation" }, ticks = 33 },
    { name = "warp_out", action = { action = "gesture", name = "warp_out" }, ticks = 20 },
    { name = "warp_in", action = { action = "gesture", name = "warp_in" }, ticks = 20 },
    { name = "nurse_bow", action = { action = "gesture", name = "nurse_bow" }, ticks = 10 },
    { name = "give", action = { action = "gesture", name = "give" }, ticks = 22 },
    { name = "receive", action = { action = "gesture", name = "receive" }, ticks = 22 },
  }

  for _, case in ipairs(cases) do
    local h = timingHarness()
    local task = startTimingTask(h, case.action, 100)
    for progress = 1, case.ticks do
      h.scheduler:step(100 + progress, nil)
      if progress < case.ticks then
        Assert.equal(
          task.status,
          "active",
          case.name
            .. " remains active before its source boundary at progress "
            .. progress
            .. " (status="
            .. task.status
            .. ", duration="
            .. tostring(task.state.durationTicks)
            .. ", progress="
            .. tostring(task.state.progressTicks)
            .. ")"
        )
      else
        Assert.equal(task.status, "completed", case.name .. " completes on its source boundary")
      end
    end
  end
end

function T.tests.gesture_duration_rejects_an_unknown_gesture_name()
  local ok, err = pcall(function()
    MovementCalibration.actionTicks({ action = "gesture", name = "unknown_gesture" })
  end)
  Assert.isFalse(ok, "an unknown gesture must fail")
  Assert.isTrue(tostring(err):find("unknown gesture", 1, true) ~= nil, "failure identifies the unknown gesture")
end

return T
