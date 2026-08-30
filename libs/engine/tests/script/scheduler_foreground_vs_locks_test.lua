local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

local function harness()
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { services = services, registry = registry, composition = composition, scheduler = scheduler }
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

function T.foreground_without_explicit_lock_must_not_suppress_player_input()
  local h = harness()
  local res = script("test.foreground_idle", {
    S.yieldTick(),
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  h.registry:installBase(res.id, res, "generated")
  local composed = assert(h.composition:effective(res.id))
  h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)

  Assert.notNil(h.scheduler:foregroundEnvironmentId(), "foreground must be active")
  -- Player input must not be considered locked simply because a foreground exists.
  Assert.isFalse(
    h.scheduler:explicitPlayerLocked(),
    "foreground without explicit player lock must not report player movement locked"
  )
end

function T.autonomous_lock_alone_must_not_imply_player_lock()
  local envMod = require("libs.engine.src.script.ScriptEnvironment")
  local env = envMod.new({ environmentId = "env-test", mode = "foreground", createdAtTick = 0 })
  env:acquireLock(envMod.LOCK_AUTONOMOUS, nil, "owner-a")
  -- Only autonomous is held; player must remain unlocked.
  Assert.isFalse(env:playerLocked(), "autonomous alone must not be reported as player locked")
  Assert.equal(env:lockCount(envMod.LOCK_PLAYER), 0)
  Assert.equal(env:lockCount(envMod.LOCK_AUTONOMOUS), 1)

  -- LockAll acquires both; releasing player must leave autonomous true and player false.
  local env2 = envMod.new({ environmentId = "env-test-2", mode = "foreground", createdAtTick = 0 })
  env2:acquireLock(envMod.LOCK_PLAYER, nil, "owner-b")
  env2:acquireLock(envMod.LOCK_AUTONOMOUS, nil, "owner-b")
  env2:releaseLock(envMod.LOCK_PLAYER, nil, "owner-b")
  Assert.isFalse(env2:playerLocked(), "after releasing player, player lock must be false while autonomous remains")
  Assert.equal(env2:lockCount(envMod.LOCK_PLAYER), 0)
  Assert.equal(env2:lockCount(envMod.LOCK_AUTONOMOUS), 1)
end

function T.foreground_lifecycle_clears_all_locks_on_completion_and_fault()
  local h = harness()
  local res = script("test.lock_release_on_end", {
    S.lockAll(),
    S.setVar({ variable = "VAR_A", value = 1 }),
    S.stop(),
  })
  h.registry:installBase(res.id, res, "generated")
  local composed = assert(h.composition:effective(res.id))
  h.scheduler:createForeground(composed, nil, 200)
  h.scheduler:step(200, nil)
  h.scheduler:step(201, nil)
  Assert.isNil(h.scheduler:foregroundEnvironmentId(), "foreground must be gone after normal completion")
  Assert.isFalse(h.scheduler:explicitPlayerLocked(), "no lock must remain after completion")

  local h2 = harness()
  local faultRes = script("test.fault", {
    S.lockPlayer(),
    S.call({ target = "scripts.nowhere" }),
    S.stop(),
  })
  h2.registry:installBase(faultRes.id, faultRes, "generated")
  local composed2 = assert(h2.composition:effective(faultRes.id))
  h2.scheduler:createForeground(composed2, nil, 300)
  h2.scheduler:step(300, nil)
  Assert.isNil(h2.scheduler:foregroundEnvironmentId(), "foreground must be gone after fault")
  Assert.isFalse(h2.scheduler:explicitPlayerLocked(), "no lock must remain after fault")
end

return { tests = T }
