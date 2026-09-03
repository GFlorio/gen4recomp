-- Actor oscillation task tests: Burned Tower source sequence,
-- Rayquaza amplitude, nondividing step, cancellation, validation,
-- shared presentation offsets, and literal/reference amplitude equivalence.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local Diagnostics = require("libs.script.src.Diagnostics")
local FakeServices = require("tests.support.script.FakeServices")
local ActorOscillationTask = require("libs.hgss.src.script.tasks.ActorOscillationTask")
local WaitTicksTask = require("libs.script.src.tasks.WaitTicksTask")

local T = {}

local function harness()
  local services = FakeServices.new()
  local actors = services.actors
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  ---@diagnostic disable-next-line: param-type-mismatch
  taskRegistry:register(ActorOscillationTask.type, ActorOscillationTask.version, ActorOscillationTask)
  ---@diagnostic disable-next-line: param-type-mismatch
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local recorder = Diagnostics.newTraceRecorder()
  local scheduler = Scheduler.new({
    semantics = require("libs.hgss.src.script.RuntimeValues"),
    services = services,
    taskRegistry = taskRegistry,
    trace = function(record)
      recorder:record(record)
    end,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    actors = actors,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    trace = recorder,
  }
end

local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function script(id, stepsOrSpec)
  if type(stepsOrSpec) == "table" and stepsOrSpec.steps ~= nil then
    stepsOrSpec.api = 1
    stepsOrSpec.id = id
    return S.script(stepsOrSpec)
  end
  return S.script({ api = 1, id = id, steps = stepsOrSpec })
end

T["Burned Tower oscillation matches source"] = function()
  local h = harness()
  h.services.actors:add("suicune", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.osc1", { S.waitTicks({ ticks = 20 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("actor_oscillation", {
    actor = "suicune",
    cycles = 2,
    degreesPerTick = 90,
    amplitudeX = 0.125,
    amplitudeZ = 0,
  }, instance, 100, nil)
  local task = assert(h.scheduler:taskById(taskId))
  local offsets = {}
  for i = 1, 8 do
    h.scheduler:step(100 + i, nil)
    ---@diagnostic disable-next-line: undefined-field
    local off = h.services.actors.actors.suicune.presentationOffset
    -- while active, offset is stored; after completion it should be zero
    if task.status == "active" or i < 8 then
      offsets[#offsets + 1] = off.x
    end
  end
  -- Two repetitions of 0, +0.125, 0, -0.125
  local expected = { 0, 0.125, 0, -0.125, 0, 0.125, 0, -0.125 }
  -- task polls: first poll applies sin(0)=0, second sin(90)=1*0.125, third sin(180)=0, fourth sin(270)=-0.125 etc.
  for i = 1, 8 do
    local exp = expected[i]
    -- Offsets after i-th poll: for i <8 task still active, offset equals expected[i]
    -- For final poll, offset is cleared to zero and task completes.
    if i < 8 then
      Assert.near(offsets[i], exp, 1e-9, "poll " .. i .. " x offset")
    end
  end
  Assert.equal(task.status, "completed", "task completes after 8 polls")
  local final = h.services.actors.actors.suicune.presentationOffset
  Assert.near(final.x, 0, 1e-9)
  Assert.near(final.z, 0, 1e-9)
  -- Script remains blocked until poll 8; continuation would be at 109 (one tick after completion)
  -- Here we used raw task, not script blocking; verify task completed at tick 108
  Assert.equal(task.completedAtTick, 108)
end

-- Rayquaza amplitude 0.1875 for eight cycles
T["Rayquaza amplitude uses normalized 0.1875"] = function()
  local h = harness()
  h.services.actors:add("rayquaza", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.ray", { S.waitTicks({ ticks = 100 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("actor_oscillation", {
    actor = "rayquaza",
    cycles = 8,
    degreesPerTick = 90,
    amplitudeX = 0.1875,
    amplitudeZ = 0,
  }, instance, 100, nil)
  local task = assert(h.scheduler:taskById(taskId))
  h.scheduler:step(101, nil)
  Assert.near(h.services.actors.actors.rayquaza.presentationOffset.x, 0, 1e-9)
  h.scheduler:step(102, nil)
  Assert.near(h.services.actors.actors.rayquaza.presentationOffset.x, 0.1875, 1e-9)
  h.scheduler:step(103, nil)
  Assert.near(h.services.actors.actors.rayquaza.presentationOffset.x, 0, 1e-9)
  h.scheduler:step(104, nil)
  Assert.near(h.services.actors.actors.rayquaza.presentationOffset.x, -0.1875, 1e-9)
  for i = 105, 132 do
    h.scheduler:step(i, nil)
  end
  Assert.equal(task.status, "completed")
  Assert.near(h.services.actors.actors.rayquaza.presentationOffset.x, 0, 1e-9)
end

T["nondividing step resets without remainder"] = function()
  local h = harness()
  h.services.actors:add("obj", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.nodiv", { S.waitTicks({ ticks = 20 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  -- step 100 does not divide 360, ceil(360/100)=4 polls per cycle
  local taskId = h.scheduler:createTask("actor_oscillation", {
    actor = "obj",
    cycles = 2,
    degreesPerTick = 100,
    amplitudeX = 1,
    amplitudeZ = 1,
  }, instance, 100, nil)
  local task = assert(h.scheduler:taskById(taskId))
  -- 4 polls complete one cycle (0,100,200,300 -> next would be 400 >=360 reset)
  for i = 1, 4 do
    h.scheduler:step(100 + i, nil)
  end
  Assert.equal(task.state.remainingCycles, 1, "one cycle decremented after 4 polls")
  Assert.equal(task.state.angle, 0, "angle resets to 0 without remainder")
  for i = 5, 8 do
    h.scheduler:step(100 + i, nil)
  end
  Assert.equal(task.status, "completed")
  Assert.near(h.services.actors.actors.obj.presentationOffset.x, 0, 1e-9)
  Assert.near(h.services.actors.actors.obj.presentationOffset.z, 0, 1e-9)
end

T["cancellation clears offset"] = function()
  local h = harness()
  h.services.actors:add("obj2", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource = script("test.cancel", { S.waitTicks({ ticks = 20 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  h.scheduler:createTask("actor_oscillation", {
    actor = "obj2",
    cycles = 5,
    degreesPerTick = 90,
    amplitudeX = 0.125,
    amplitudeZ = 0.125,
  }, instance, 100, nil)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  -- offset should be +0.125
  Assert.near(h.services.actors.actors.obj2.presentationOffset.x, 0.125, 1e-9)
  h.scheduler:cancelEnvironment(assert(h.scheduler:foregroundEnvironmentId()), "test cancel")
  Assert.near(h.services.actors.actors.obj2.presentationOffset.x, 0, 1e-9)
  Assert.near(h.services.actors.actors.obj2.presentationOffset.z, 0, 1e-9)
end

T["validation rejects zero cycles and step and non-finite amplitudes"] = function()
  Assert.notNil(ActorOscillationTask.validate)
  local bad1 = { actor = "a", remainingCycles = 0, angle = 0, degreesPerTick = 90, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.notNil(ActorOscillationTask.validate(bad1))
  local bad2 = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 0, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.notNil(ActorOscillationTask.validate(bad2))
  local bad3 =
    { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = math.huge, amplitudeZ = 0 }
  Assert.notNil(ActorOscillationTask.validate(bad3))
  local bad4 = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = 0 / 0, amplitudeZ = 0 }
  Assert.notNil(ActorOscillationTask.validate(bad4))
  local good = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.isNil(ActorOscillationTask.validate(good))
end

-- Oscillation runs against the shared fake actor contract: the fake owns a
-- zeroed presentation offset per actor, polls write observable sine offsets,
-- and both normal completion and cancellation clear back to zero.
T["oscillation writes and clears shared actor presentation offsets"] = function()
  local h = harness()
  h.services.actors:add("dancer", { fieldX = 0, fieldZ = 0, facing = "south" })
  ---@diagnostic disable-next-line: undefined-field
  local initial =
    ---@diagnostic disable-next-line: undefined-field
    assert(h.services.actors.actors.dancer.presentationOffset, "the shared fake owns a presentation offset")
  Assert.deepEqual(initial, { x = 0, y = 0, z = 0 })
  local resource = script("test.shared_offset_complete", { S.waitTicks({ ticks = 20 }) })
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  local instanceId = h.scheduler:createForeground(composed, nil, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("actor_oscillation", {
    actor = "dancer",
    cycles = 2,
    degreesPerTick = 90,
    amplitudeX = 0.125,
    amplitudeZ = 0,
  }, instance, 100, nil)
  local task = assert(h.scheduler:taskById(taskId))
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  ---@diagnostic disable-next-line: undefined-field
  Assert.near(h.services.actors.actors.dancer.presentationOffset.x, 0.125, 1e-9)
  for tick = 103, 108 do
    h.scheduler:step(tick, nil)
  end
  Assert.equal(task.status, "completed")
  ---@diagnostic disable-next-line: undefined-field
  Assert.deepEqual(h.services.actors.actors.dancer.presentationOffset, { x = 0, y = 0, z = 0 })

  local c = harness()
  c.services.actors:add("spinner", { fieldX = 0, fieldZ = 0, facing = "south" })
  local resource2 = script("test.shared_offset_cancel", { S.waitTicks({ ticks = 20 }) })
  if c.registry:base(resource2.id) == nil then
    c.registry:installBase(resource2.id, resource2, "generated")
  end
  local composed2 = assert(c.composition:effective(resource2.id))
  local instanceId2 = c.scheduler:createForeground(composed2, nil, 200)
  local instance2 = assert(c.scheduler:instance(instanceId2))
  c.scheduler:createTask("actor_oscillation", {
    actor = "spinner",
    cycles = 5,
    degreesPerTick = 90,
    amplitudeX = 0.125,
    amplitudeZ = 0.125,
  }, instance2, 200, nil)
  c.scheduler:step(201, nil)
  c.scheduler:step(202, nil)
  ---@diagnostic disable-next-line: undefined-field
  Assert.near(c.services.actors.actors.spinner.presentationOffset.x, 0.125, 1e-9)
  c.scheduler:cancelEnvironment(assert(c.scheduler:foregroundEnvironmentId()), "test cancel")
  ---@diagnostic disable-next-line: undefined-field
  Assert.deepEqual(c.services.actors.actors.spinner.presentationOffset, { x = 0, y = 0, z = 0 })
end

T["literal and referenced amplitudes share the same displacement unit"] = function()
  local function peakFor(scriptId, actorId, steps)
    local h = harness()
    h.services.actors:add(actorId, { fieldX = 0, fieldZ = 0, facing = "south" })
    local resource = script(scriptId, steps)
    if h.registry:base(resource.id) == nil then
      h.registry:installBase(resource.id, resource, "generated")
    end
    local composed = assert(h.composition:effective(resource.id))
    h.scheduler:createForeground(composed, nil, 100)
    h.scheduler:step(100, nil)
    h.scheduler:step(101, nil)
    h.scheduler:step(102, nil)
    ---@diagnostic disable-next-line: undefined-field
    return h.services.actors.actors[actorId].presentationOffset.x
  end
  local literalPeak = peakFor("test.osc_literal_unit", "literal_dancer", {
    S.actorOscillate({ actor = "literal_dancer", cycles = 1, degreesPerTick = 90, amplitudeX = 0.125, amplitudeZ = 0 }),
  })
  Assert.near(literalPeak, 0.125, 1e-9, "literal amplitude peak")
  local referencedPeak = peakFor("test.osc_reference_unit", "reference_dancer", {
    locals = { amp = "number" },
    steps = {
      S.setLocal({ name = "amp", value = 0.125 }),
      S.actorOscillate({
        actor = "reference_dancer",
        cycles = 1,
        degreesPerTick = 90,
        amplitudeX = S.local_("amp"),
        amplitudeZ = 0,
      }),
    },
  })
  Assert.near(referencedPeak, 0.125, 1e-9, "referenced amplitude peak")
end

return { tests = T }
