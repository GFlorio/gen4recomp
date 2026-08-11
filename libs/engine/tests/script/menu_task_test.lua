-- MenuTask scheduler tests: a registered task owns menu input and lifetime,
-- while the scheduler remains responsible for writing its result and resuming
-- the blocked script on a later tick.

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local RawModules = require("libs.engine.src.script.RawModules")
local MenuTask = require("libs.engine.src.script.tasks.MenuTask")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

local RecordingMenuHost = {}
RecordingMenuHost.__index = RecordingMenuHost

function RecordingMenuHost.new()
  return setmetatable({ syncs = {}, closes = 0 }, RecordingMenuHost)
end

function RecordingMenuHost:sync(state)
  self.syncs[#self.syncs + 1] = {
    selectedIndex = state.selectedIndex,
    scrollPosition = state.scrollPosition,
    pressedPointerItem = state.pressedPointerItem,
  }
end

function RecordingMenuHost:close()
  self.closes = self.closes + 1
end

local TestRaw = {
  startMenu = function()
    return {
      taskType = "menu",
      taskVersion = 1,
      state = {
        menu = {
          items = {
            { text = "First", value = 41 },
            { text = "Second", value = 99 },
          },
          initialCursor = 0,
          cancellable = true,
          cancelValue = -1,
        },
      },
    }
  end,
}

local RecordingScriptMenuHost = {}
RecordingScriptMenuHost.__index = RecordingScriptMenuHost

function RecordingScriptMenuHost.new()
  return setmetatable({ builder = nil, requests = {} }, RecordingScriptMenuHost)
end

function RecordingScriptMenuHost:beginMenu(spec)
  assert(self.builder == nil, "test menu builder is already active")
  self.builder = {
    messageSource = spec.messageSource,
    sourcePlacement = spec.sourcePlacement,
    initialCursor = spec.initialCursor,
    cancellable = spec.cancellable,
    result = spec.result,
    items = {},
  }
end

function RecordingScriptMenuHost:addItem(item)
  self.builder.items[#self.builder.items + 1] = item
end

function RecordingScriptMenuHost:execute()
  local request = self.builder
  self.builder = nil
  self.requests[#self.requests + 1] = request
  return request
end

local function harness()
  local services = FakeServices.new()
  local host = RecordingMenuHost.new()
  local scriptMenu = RecordingScriptMenuHost.new()
  services.menu = host
  services.scriptMenu = scriptMenu
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register(MenuTask.type, MenuTask.version, MenuTask)
  local modules = RawModules.new()
  modules:register("test.menu", TestRaw, { kind = "mod", id = "test", api = 1 })
  services.rawModules = modules
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    host = host,
    scriptMenu = scriptMenu,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
  }
end

function T.menu_builder_operations_yield_add_same_tick_and_block_for_the_script_result()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.menu_builder",
    steps = {
      S.setVar({ variable = "VAR_MESSAGE", value = 0 }),
      S.setVar({ variable = "VAR_METADATA", value = 73 }),
      S.setVar({ variable = "VAR_VALUE", value = 99 }),
      S.menuBegin({
        messageSource = "standard",
        sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 17, y = 5 },
        initialCursor = 0,
        cancellable = false,
        result = S.var("VAR_RESULT"),
      }),
      S.menuAdd({
        messageId = S.var("VAR_MESSAGE"),
        vanillaMetadata = S.var("VAR_METADATA"),
        value = S.var("VAR_VALUE"),
      }),
      S.menuExec(),
      S.setVar({ variable = "VAR_AFTER_MENU", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.equal(#h.scriptMenu.requests, 0, "menu initialization yields before the add and exec operations")
  h.scheduler:step(101, {})
  Assert.equal(#h.scriptMenu.requests, 1)
  local request = h.scriptMenu.requests[1]
  Assert.equal(request.messageSource, "standard")
  Assert.equal(request.sourcePlacement.x, 17)
  Assert.equal(request.items[1].messageId, 0)
  Assert.equal(request.items[1].vanillaMetadata, 73)
  Assert.equal(request.items[1].value, 99)
  Assert.equal(h.services.world:getVar("VAR_AFTER_MENU"), 0)

  h.scheduler:step(102, { menuEvents = { { type = "confirm" } } })
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 0)
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 99)
  Assert.equal(h.services.world:getVar("VAR_AFTER_MENU"), 1)
end

local function resource()
  return S.script({
    api = 1,
    id = "test.menu_task",
    locals = { selection = "integer" },
    steps = {
      S.lua({ module = "test.menu", fn = "startMenu", result = S.local_("selection") }),
      S.setVar({ variable = "VAR_RESULT", value = S.local_("selection") }),
      S.stop(),
    },
  })
end

local function start(h, tick)
  local script = resource()
  h.registry:installBase(script.id, script, "generated")
  return h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, tick)
end

function T.menu_task_blocks_until_normalized_confirmation_then_resumes_the_script()
  local h = harness()
  start(h, 100)
  h.scheduler:step(100, {})
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 0)
  h.scheduler:step(101, { menuEvents = { { type = "navigate", direction = "down" } } })
  Assert.equal(h.host.syncs[#h.host.syncs].selectedIndex, 1)
  h.scheduler:step(102, { menuEvents = { { type = "confirm" } } })
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 0, "completion cannot continue the script in its poll tick")
  Assert.equal(h.host.closes, 1)
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_RESULT"), 99)
end

function T.menu_task_restores_its_logical_selection_without_serializing_presentation_state()
  local h = harness()
  start(h, 100)
  h.scheduler:step(100, {})
  h.scheduler:step(101, { menuEvents = { { type = "navigate", direction = "down" } } })
  local bucket = ScriptSave.capture(h.scheduler, 101, { registryFingerprint = h.registry:fingerprint() })
  local state = bucket.tasks[1].state
  Assert.equal(state.selectedIndex, 1)
  Assert.equal(state.scrollPosition, 0)
  Assert.equal(state.pressedPointerItem, nil)

  local h2 = harness()
  h2.registry:installBase("test.menu_task", resource(), "generated")
  ScriptSave.restore(bucket, h2.scheduler, 101, {})
  h2.scheduler:step(102, { menuEvents = { { type = "confirm" } } })
  h2.scheduler:step(103, {})
  Assert.equal(h2.services.world:getVar("VAR_RESULT"), 99)
  Assert.equal(h2.host.syncs[#h2.host.syncs].selectedIndex, 1)
  Assert.equal(h2.host.closes, 1)
end

function T.cancelling_the_blocked_script_releases_the_menu_once()
  local h = harness()
  local instanceId = start(h, 100)
  h.scheduler:step(100, {})
  h.scheduler:cancelInstance(instanceId, "test cancellation")
  Assert.equal(h.host.closes, 1)
  Assert.equal(#h.scheduler:tasks(), 0)
end

function T.menu_task_rejects_non_finite_or_out_of_range_saved_logical_state()
  local state = MenuTask.create(
    { menu = TestRaw.startMenu().state.menu },
    { services = { menu = RecordingMenuHost.new() } }
  )
  state.scrollPosition = math.huge
  local err = MenuTask.validate(state)
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")

  state.scrollPosition = 0
  state.selectedIndex = 2
  err = MenuTask.validate(state)
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")

  state.selectedIndex = 0
  state.pressedPointerItem = -1
  err = MenuTask.validate(state)
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
end

return T
