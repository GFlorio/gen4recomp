-- Actor oscillation task tests: Burned Tower source sequence,
-- Rayquaza amplitude, nondividing step, cancellation, validation,
-- and presentation offset Z plumbing.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.script.src.Registry")
local Composition = require("libs.script.src.Composition")
local TaskRegistry = require("libs.script.src.TaskRegistry")
local Scheduler = require("libs.script.src.Scheduler")
local ScriptSave = require("libs.script.src.ScriptSave")
local Diagnostics = require("libs.script.src.Diagnostics")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

local function harness()
  local services = FakeServices.new()
  -- Extend fake actors with presentation offset support.
  local actors = services.actors
  for _, actor in pairs(actors.actors) do
    actor.presentationOffset = { x = 0, y = 0, z = 0 }
  end
  function actors:setPresentationOffset(actorId, offset)
    local actor = assert(self.actors[actorId], "fake actor missing: " .. actorId)
    if actorId == "player" then
      Errors.raise("SCRIPT_ACTOR_NOT_FOUND", "player not supported for oscillation", { actor = actorId })
    end
    actor.presentationOffset = { x = offset.x or 0, y = offset.y or 0, z = offset.z or 0 }
    actor.lastOffset =
      { x = actor.presentationOffset.x, y = actor.presentationOffset.y, z = actor.presentationOffset.z }
  end
  function actors:clearPresentationOffset(actorId)
    self:setPresentationOffset(actorId, { x = 0, y = 0, z = 0 })
  end
  -- Also support manager-style direct if ScriptActorWorld delegates.
  actors._offsets = {}
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  local ok, mod = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  if ok then
    taskRegistry:register(mod.type, mod.version, mod)
  else
    -- before implementation, register a stub that will cause poll to fail
    -- keep registry empty so task creation faults with missing type
  end
  taskRegistry:register("wait_ticks", 1, require("libs.script.src.tasks.WaitTicksTask"))
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

-- A-D03-01: Burned Tower oscillation matches source (2,90,2,0) => 0.125 tile
T["Burned Tower oscillation matches source"] = function()
  local modOk = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  Assert.isTrue(modOk, "ActorOscillationTask module must exist")
  local h = harness()
  h.services.actors:add("suicune", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors.actors.suicune.presentationOffset = { x = 0, y = 0, z = 0 }
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
    local off = h.services.actors.actors.suicune.presentationOffset or h.services.actors.actors.suicune.lastOffset
    -- while active, offset is stored; after completion it should be zero
    if task.status == "active" or i < 8 then
      offsets[#offsets + 1] = off.x
    end
  end
  -- Two repetitions of 0, +0.125, 0, -0.125
  local expected = { 0, 0.125, 0, -0.125, 0, 0.125, 0, -0.125 }
  -- task polls: first poll applies sin(0)=0, second sin(90)=1*0.125, third sin(180)=0, fourth sin(270)=-0.125 etc.
  -- Our collection above captures offset applied during poll; need to check per poll.
  -- Instead re-derive via lastOffset history; simpler to check sequence directly.
  -- Due to harness, we captured after each step; adjust tolerance.
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
  local modOk = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  Assert.isTrue(modOk, "module required")
  local h = harness()
  h.services.actors:add("rayquaza", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors.actors.rayquaza.presentationOffset = { x = 0, y = 0, z = 0 }
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

-- A-D03-02: nondividing step
T["nondividing step resets without remainder"] = function()
  local modOk = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  Assert.isTrue(modOk, "module required")
  local h = harness()
  h.services.actors:add("obj", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors.actors.obj.presentationOffset = { x = 0, y = 0, z = 0 }
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
  local modOk = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  Assert.isTrue(modOk, "module required")
  local h = harness()
  h.services.actors:add("obj2", { fieldX = 0, fieldZ = 0, facing = "south" })
  h.services.actors.actors.obj2.presentationOffset = { x = 0, y = 0, z = 0 }
  local resource = script("test.cancel", { S.waitTicks({ ticks = 20 }) })
  local instanceId = startForeground(h, resource, 100)
  local instance = assert(h.scheduler:instance(instanceId))
  local taskId = h.scheduler:createTask("actor_oscillation", {
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
  local ok, mod = pcall(require, "libs.hgss.src.script.tasks.ActorOscillationTask")
  Assert.isTrue(ok, "module required")
  Assert.notNil(mod.validate)
  local bad1 = { actor = "a", remainingCycles = 0, angle = 0, degreesPerTick = 90, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.notNil(mod.validate(bad1))
  local bad2 = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 0, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.notNil(mod.validate(bad2))
  local bad3 =
    { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = math.huge, amplitudeZ = 0 }
  Assert.notNil(mod.validate(bad3))
  local bad4 = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = 0 / 0, amplitudeZ = 0 }
  Assert.notNil(mod.validate(bad4))
  local good = { actor = "a", remainingCycles = 1, angle = 0, degreesPerTick = 90, amplitudeX = 0.125, amplitudeZ = 0 }
  Assert.isNil(mod.validate(good))
end

T["lowering handler 523 normalizes amplitudes"] = function()
  local ok, FieldHandlers = pcall(require, "romdump.src.digest.script.lowering.FieldHandlers")
  if not ok then
    Assert.isTrue(false, "FieldHandlers must be loadable")
  end
  -- numeric amplitudes should be divided by 16
  local fakeIns = {
    opcode = 523,
    operands = { { raw = 3 }, { raw = 2 }, { raw = 90 }, { raw = 2 }, { raw = 3 } },
    offset = 0x20,
  }
  local handler = FieldHandlers[523]
  Assert.notNil(handler, "handler 523 must exist")
  local node = handler(fakeIns)
  Assert.equal(node.op, "actor_oscillate")
  Assert.near(node.amplitudeX, 0.125, 1e-9)
  Assert.near(node.amplitudeZ, 0.1875, 1e-9)
  Assert.equal(node.cycles, 2)
  Assert.equal(node.degreesPerTick, 90)
  -- var ref case: operands that are var-range should stay as var refs
  local varIns = {
    opcode = 523,
    operands = { { raw = 3 }, { raw = 0x4000 }, { raw = 0x4001 }, { raw = 0x4002 }, { raw = 0x4003 } },
    offset = 0x20,
  }
  local varNode = handler(varIns)
  Assert.equal(varNode.cycles.value, "var")
  Assert.equal(varNode.degreesPerTick.value, "var")
  Assert.equal(varNode.amplitudeX.value, "var")
end

T["script actor world rejects player for oscillation"] = function()
  local ok, SAW = pcall(require, "libs.hgss.src.script.ScriptActorWorld")
  Assert.isTrue(ok, "ScriptActorWorld loadable")
  local manager = {
    getActor = function()
      return {}
    end,
    show = function() end,
    hide = function() end,
    setPosition = function() end,
    setFacing = function() end,
    setMovementType = function() end,
    setAnimationPaused = function() end,
    getPosition = function()
      return { fieldX = 0, fieldZ = 0 }
    end,
    getFacing = function()
      return "south"
    end,
    numericId = function()
      return 1
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
    setPresentationOffset = function() end,
    clearPresentationOffset = function() end,
  }
  local player = {
    position = function()
      return { fieldX = 0, fieldZ = 0 }
    end,
    facing = function()
      return "south"
    end,
  }
  local world = SAW.new(manager, player)
  local threw = false
  local ok2, err = pcall(function()
    world:setPresentationOffset("player", { x = 0, y = 0, z = 0 })
  end)
  if not ok2 then
    threw = true
    Assert.isTrue(Errors.is(err) or tostring(err):find("player") ~= nil)
  end
  Assert.isTrue(threw, "player presentation offset must be rejected")
end

return { tests = T }
