-- World state tests : the project-owned flag
-- and variable stores, symbol catalog resolution, the serialized script RNG,
-- and the global-vs-instance-local classification rules (persistent scene
-- variables survive save; temporary locals do not persist after instance
-- completion). New Bark branching can be driven by save
-- state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local ScriptRng = require("libs.engine.src.script.ScriptRng")
local WorldState = require("libs.engine.src.script.WorldState")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

-- A WorldState-backed services world (the real game wiring shape).
local function worldServices(world)
  return {
    isFlagSet = function(_, id)
      return world:isFlagSet(id)
    end,
    setFlag = function(_, id)
      world:setFlag(id)
    end,
    clearFlag = function(_, id)
      world:clearFlag(id)
    end,
    getVar = function(_, id)
      return world:getVar(id)
    end,
    setVar = function(_, id, value)
      world:setVar(id, value)
    end,
    addVar = function(_, id, amount)
      world:addVar(id, amount)
    end,
    subVar = function(_, id, amount)
      world:subVar(id, amount)
    end,
    rng = world.rng,
  }
end

local CATALOGS = {
  flags = { FLAG_MET_ELM = 0x800, FLAG_GOT_STARTER = 0x801 },
  variables = {
    VAR_SCENE_NEW_BARK_TOWN_OW = 0x4000,
    VAR_SCENE_ELMS_LAB = 0x4001,
    VAR_SPECIAL_RESULT = 0x800C,
  },
}

---@return table harness
local function harness()
  local world = WorldState.new({ catalogs = CATALOGS, seed = 42 })
  local services = FakeServices.new()
  services.world = worldServices(world)
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
  return {
    world = world,
    services = services,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

local function script(id, stepsOrSpec)
  if type(stepsOrSpec) == "table" and stepsOrSpec.steps ~= nil then
    stepsOrSpec.api = 1
    stepsOrSpec.id = id
    return S.script(stepsOrSpec)
  end
  return S.script({ api = 1, id = id, steps = stepsOrSpec })
end

-- 1. Symbolic flags and variables resolve through the catalog to the numeric
-- store; the underlying FieldEventState sees numeric ids.
T["symbol catalog resolution"] = function()
  local h = harness()
  h.world:setFlag("FLAG_MET_ELM")
  h.world:setVar("VAR_SCENE_NEW_BARK_TOWN_OW", 2)
  Assert.isTrue(h.world:isFlagSet("FLAG_MET_ELM"))
  Assert.isFalse(h.world:isFlagSet("FLAG_GOT_STARTER"))
  Assert.equal(h.world:getVar("VAR_SCENE_NEW_BARK_TOWN_OW"), 2)
  Assert.equal(h.world:events():isFlagSet(0x800), true)
  Assert.equal(h.world:events():getVar(0x4000), 2)
end

-- 2. Unknown symbolic references are attributed errors.
T["unknown symbol errors"] = function()
  local h = harness()
  local ok = pcall(function()
    h.world:setFlag("FLAG_TYPO")
  end)
  Assert.isFalse(ok)
  local ok2 = pcall(function()
    h.world:getVar("VAR_TYPO")
  end)
  Assert.isFalse(ok2)
end

-- 3. Flag conditions and dynamic flag ids execute through the catalog-backed
-- world.
T["flag condition and dynamic ids"] = function()
  local h = harness()
  local flagsResource = script("test.flags", {
    S.if_({
      condition = S.flag("FLAG_MET_ELM"),
      yes = { S.setFlag({ flag = "FLAG_GOT_STARTER" }), S.stop() },
      no = { S.setVar({ variable = "VAR_SCENE_ELMS_LAB", value = 9 }), S.stop() },
    }),
  })
  h.world:setFlag("FLAG_MET_ELM")
  h.registry:installBase(flagsResource.id, flagsResource, "generated")
  local dynamicResource = script("test.dynamic", {
    S.setVar({ variable = "VAR_SPECIAL_RESULT", value = 0x801 }),
    S.setFlag({ flag = S.var("VAR_SPECIAL_RESULT") }),
    S.stop(),
  })
  h.registry:installBase(dynamicResource.id, dynamicResource, "generated")
  local composed = assert(h.composition:effective("test.flags"))
  h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.isTrue(h.world:isFlagSet("FLAG_GOT_STARTER"))
  Assert.equal(h.world:getVar("VAR_SCENE_ELMS_LAB"), 0)
  local composed2 = assert(h.composition:effective("test.dynamic"))
  h.scheduler:createForeground(composed2, nil, 101)
  h.scheduler:step(101, nil)
  Assert.isTrue(h.world:events():isFlagSet(0x801))
end

-- 4. Persistent variables survive a save/load cycle through the world bucket.
T["persistent variables survive save"] = function()
  local h = harness()
  local persistResource = script("test.persist", {
    S.setVar({ variable = "VAR_SCENE_NEW_BARK_TOWN_OW", value = 1 }),
    S.waitTicks({ ticks = 3 }),
    S.stop(),
  })
  h.registry:installBase(persistResource.id, persistResource, "generated")
  local composed = assert(h.composition:effective("test.persist"))
  h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)
  local bucket = ScriptSave.capture(h.scheduler, 100, { registryFingerprint = h.registry:fingerprint() })
  Assert.isNil(bucket.world)
  local worldRecord = h.world:capture()
  Assert.equal(worldRecord.variables[0x4000], 1)
  local restoredWorld = WorldState.restore(worldRecord, { catalogs = CATALOGS })
  Assert.equal(restoredWorld:getVar("VAR_SCENE_NEW_BARK_TOWN_OW"), 1)
end

-- 5. Temporary locals do not persist after instance completion: the ended
-- root is dropped entirely, so neither its locals nor any record of the
-- instance survive.
T["temp locals do not persist after completion"] = function()
  local h = harness()
  local resource = script("test.locals", {
    locals = { temp = "integer" },
    steps = {
      S.setLocal({ name = "temp", value = 7 }),
      S.waitTicks({ ticks = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  local instanceId = h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).locals.temp, 7)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.isNil(h.scheduler:instance(instanceId), "the ended root is not retained")
end

-- 6. The script RNG is deterministic, serializable, and seeded from state.
T["script rng determinism and save"] = function()
  local a = ScriptRng.new("save-seed-1")
  local b = ScriptRng.new("save-seed-1")
  for _ = 1, 5 do
    Assert.equal(a:nextInt(100), b:nextInt(100))
  end
  local state = a:serialize()
  local restored = ScriptRng.restore(state)
  Assert.equal(restored:nextInt(100), b:nextInt(100))
  Assert.equal(ScriptRng.deriveSeed("x"), ScriptRng.deriveSeed("x"))
  Assert.isFalse(ScriptRng.deriveSeed("x") == ScriptRng.deriveSeed("y"))
end

-- 7. WorldState round trip: flags, variables, and rng state all restore.
T["world state round trip"] = function()
  local world = WorldState.new({ catalogs = CATALOGS, seed = 7 })
  world:setFlag("FLAG_MET_ELM")
  world:setVar("VAR_SCENE_ELMS_LAB", 2)
  world.rng:nextInt(50)
  local record = world:capture()
  local restored = WorldState.restore(record, { catalogs = CATALOGS })
  Assert.isTrue(restored:isFlagSet("FLAG_MET_ELM"))
  Assert.equal(restored:getVar("VAR_SCENE_ELMS_LAB"), 2)
  Assert.equal(restored.rng:nextInt(50), world.rng:nextInt(50), "the serialized RNG continues from the captured state")
end

-- 8. The new-bark branching scenario: scene variable drives the branch and
-- save state selects every branch.
T["new bark branching driven by save state"] = function()
  local h = harness()
  local resource = script("new_bark.npc.woman_1", {
    S.if_({
      condition = S.eq(S.var("VAR_SCENE_NEW_BARK_TOWN_OW"), 0),
      yes = { S.setVar({ variable = "VAR_SCENE_ELMS_LAB", value = 1 }), S.stop() },
      no = { S.setVar({ variable = "VAR_SCENE_ELMS_LAB", value = 2 }), S.stop() },
    }),
  })
  h.registry:installBase(resource.id, resource, "generated")
  h.world:setVar("VAR_SCENE_NEW_BARK_TOWN_OW", 0)
  local composed = assert(h.composition:effective(resource.id))
  h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.world:getVar("VAR_SCENE_ELMS_LAB"), 1)

  local h2 = harness()
  h2.world:setVar("VAR_SCENE_NEW_BARK_TOWN_OW", 3)
  h2.registry:installBase(resource.id, resource, "generated")
  local composed2 = assert(h2.composition:effective(resource.id))
  h2.scheduler:createForeground(composed2, nil, 100)
  h2.scheduler:step(100, nil)
  Assert.equal(h2.world:getVar("VAR_SCENE_ELMS_LAB"), 2)
end

-- 9. A present-but-malformed rng value is rejected instead of silently
-- dropped: losing serialized RNG state would silently break determinism.
T["restoreRng rejects a malformed rng value"] = function()
  local world = WorldState.new({ catalogs = CATALOGS, seed = 7 })
  local err = Assert.throws(function()
    world:restoreRng({ rng = "malformed" })
  end)
  Assert.isTrue(
    err ~= nil and err.code == "SCRIPT_TASK_UNSERIALIZABLE",
    "expected SCRIPT_TASK_UNSERIALIZABLE, got " .. tostring(err and err.code or err)
  )
end

-- 10. A present rng table with invalid fields is rejected the same way: the
-- rejection is a structured load error, not a raw assert or a silent drop.
T["restoreRng rejects a malformed rng table"] = function()
  local world = WorldState.new({ catalogs = CATALOGS, seed = 7 })
  local err = Assert.throws(function()
    world:restoreRng({ rng = {} })
  end)
  Assert.isTrue(
    err ~= nil and err.code == "SCRIPT_TASK_UNSERIALIZABLE",
    "expected SCRIPT_TASK_UNSERIALIZABLE, got " .. tostring(err and err.code or err)
  )
end

return T
