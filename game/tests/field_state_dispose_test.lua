-- FieldState/FieldRuntime disposal and reset contract. The single general
-- disposal hook persists the field session when one is live, releases every
-- owned resource exactly once, and is a no-op on repeat calls, so state
-- replacement and application quit can never double-save or double-release.
-- The dev-gated reset (F2) routes through that same teardown: wipe the save
-- store, release every collaborator, clear every owned field, then re-boot.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldState = require("game.src.game.FieldState")

local T = {}

-- A fake resource whose named methods record how often they are called.
---@param ... "dispose"|"release"|"save"|"reset"
local function fakeResource(...)
  local resource = {}
  for _, method in ipairs({ ... }) do
    resource[method] = function(self)
      self.calls = (self.calls or 0) + 1
    end
  end
  resource.calls = 0
  return resource
end

-- The actor asset provider is touched twice by disposal: the per-acquisition
-- release and the provider-level dispose.
local function fakeAssetProvider()
  local provider = fakeResource("dispose")
  provider.releaseCalls = 0
  function provider:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  return provider
end

-- A session in a state FieldSave can capture: player idle, no transition, no
-- modal dialogue, and a runtime map with the required terrain identity.
local function captureReadySession()
  return {
    versionId = "test",
    tick = 0,
    player = {
      motion = "idle",
      fieldX = 0,
      fieldZ = 0,
      worldY = 0,
      surfaceId = 0,
      facing = "south",
    },
    currentMap = { mapId = 0, terrainDependencyHash = "dep" },
  }
end

-- A bare FieldState (no boot) with every resource the disposal path touches.
local function disposableState()
  local resources = {
    dialogue = fakeResource("dispose"),
    dialogueRenderer = fakeResource("release"),
    messageProvider = fakeResource("dispose"),
    actors = fakeResource("dispose"),
    actorAssets = fakeAssetProvider(),
    renderer = fakeResource("release"),
    mapLoader = fakeResource("release"),
    saveStore = fakeResource("save", "reset"),
  }
  local runtime = setmetatable({
    dialogue = resources.dialogue,
    messageProvider = resources.messageProvider,
    actors = resources.actors,
    avatarAsset = {},
    actorAssets = resources.actorAssets,
    mapLoader = resources.mapLoader,
    saveStore = resources.saveStore,
    session = captureReadySession(),
    avatar = { id = "hero" },
    auxiliaryFieldUi = {
      capture = function()
        return { requested = "shown", state = "shown" }
      end,
    },
  }, FieldRuntime)
  local state = setmetatable({
    runtime = runtime,
    dialogueRenderer = resources.dialogueRenderer,
    renderer = resources.renderer,
  }, FieldState)
  return state, resources
end

function T.dispose_saves_and_releases_each_resource_exactly_once()
  local state, resources = disposableState()
  local runtime = state.runtime --[[@as any]]
  state:dispose()
  Assert.equal(resources.dialogue.calls, 1)
  Assert.equal(resources.dialogueRenderer.calls, 1)
  Assert.equal(resources.messageProvider.calls, 1)
  Assert.equal(resources.actors.calls, 1)
  Assert.equal(resources.actorAssets.releaseCalls, 1)
  Assert.equal(resources.actorAssets.calls, 1)
  Assert.equal(resources.renderer.calls, 1)
  Assert.equal(resources.mapLoader.calls, 1)
  Assert.equal(resources.saveStore.calls, 1)
  Assert.isNil(runtime.session)
end

function T.dispose_is_a_no_op_on_repeat_calls()
  local state, resources = disposableState()
  state:dispose()
  state:dispose()
  Assert.equal(resources.dialogue.calls, 1)
  Assert.equal(resources.renderer.calls, 1)
  Assert.equal(resources.saveStore.calls, 1)
end

function T.dispose_without_a_live_session_skips_the_save()
  local state, resources = disposableState()
  state.runtime.session = nil
  state:dispose()
  Assert.equal(resources.saveStore.calls, 0)
  Assert.equal(resources.renderer.calls, 1)
end

function T.dispose_on_a_failed_boot_state_is_a_no_op()
  local state = setmetatable({
    runtime = setmetatable({ errorText = "boom" }, FieldRuntime),
  }, FieldState)
  state:dispose()
end

function T.dispose_releases_runtime_and_presentation_resources_once()
  local state, resources = disposableState()
  local runtime = fakeResource("dispose")
  state.runtime = runtime
  state:dispose()
  Assert.equal(runtime.calls, 1)
  Assert.equal(resources.renderer.calls, 1)
end

-- A runtime shaped exactly like a loaded one: every owned collaborator is
-- present so reset's clearing can be asserted field by field. `_load` is
-- stubbed -- reset must release everything and then re-boot, which the test
-- observes through the stub's call count.
local function resetState()
  local state, resources = disposableState()
  local runtime = state.runtime --[[@as any]]
  runtime.scripts = {}
  runtime.transition = {}
  runtime.camera = {}
  runtime.player = {}
  runtime.runtimeMap = {}
  runtime.viewport = {}
  runtime.input = {}
  runtime.menuHost = {}
  runtime.eventState = {}
  runtime.envelope = {}
  runtime.interactionResolver = {}
  runtime.contextChoiceProvider = {}
  runtime.playerVisual = {}
  local reloads = 0
  runtime._load = function()
    reloads = reloads + 1
  end
  return state, resources, function()
    return reloads
  end
end

-- Reset shares one teardown path with dispose: wipe the save store, release
-- every owned collaborator through the same methods, clear every owned field
-- (never a hand-picked subset), and re-boot. A later dispose then has nothing
-- left to release or save.
function T.reset_routes_through_the_shared_teardown_path()
  local state, resources, reloads = resetState()
  local runtime = state.runtime --[[@as any]]
  runtime:_reset()
  Assert.equal(resources.saveStore.calls, 1, "reset wipes the save store")
  Assert.equal(resources.dialogue.calls, 1, "reset releases the dialogue")
  Assert.equal(resources.messageProvider.calls, 1, "reset releases the message provider")
  Assert.equal(resources.actors.calls, 1, "reset releases the actors")
  Assert.equal(resources.actorAssets.releaseCalls, 1, "reset releases the avatar acquisition")
  Assert.equal(resources.actorAssets.calls, 1, "reset disposes the actor assets")
  Assert.equal(resources.mapLoader.calls, 1, "reset releases the map loader")
  Assert.equal(reloads(), 1, "reset re-boots the runtime")
  for _, field in ipairs({
    "session",
    "saveStore",
    "scripts",
    "transition",
    "camera",
    "player",
    "runtimeMap",
    "viewport",
    "input",
    "menuHost",
    "eventState",
    "envelope",
    "interactionResolver",
    "auxiliaryFieldUi",
    "contextChoiceProvider",
    "avatar",
    "playerVisual",
    "avatarAsset",
    "dialogue",
    "messageProvider",
    "actors",
    "actorAssets",
    "mapLoader",
  }) do
    Assert.isNil(runtime[field], "reset must clear " .. field)
  end
  Assert.isFalse(runtime.resumeSave, "reset drops the resume flag")
  Assert.isNil(runtime.errorText, "reset clears the boot error")
  state:dispose()
  Assert.equal(resources.dialogue.calls, 1, "dispose after reset releases nothing twice")
  Assert.equal(resources.mapLoader.calls, 1, "dispose after reset releases nothing twice")
  Assert.equal(resources.saveStore.calls, 1, "dispose after reset saves nothing")
end

-- A failed save-store wipe must not tear down or re-boot the live runtime:
-- reset reports the failure and every owned collaborator stays in place.
function T.reset_failure_keeps_the_live_runtime_untouched()
  local state, resources, reloads = resetState()
  local runtime = state.runtime --[[@as any]]
  resources.saveStore.failReset = true
  resources.saveStore.reset = function(self)
    self.calls = self.calls + 1
    if self.failReset then
      error("injected reset failure")
    end
  end
  runtime:_reset()
  Assert.isTrue(runtime.saveStatus:find("Reset failed:", 1, true) ~= nil, "reset reports the wipe failure")
  Assert.notNil(runtime.session, "failed reset keeps the live session")
  Assert.notNil(runtime.mapLoader, "failed reset keeps the loaded map")
  Assert.equal(resources.mapLoader.calls, 0, "failed reset releases nothing")
  Assert.equal(resources.dialogue.calls, 0, "failed reset releases nothing")
  Assert.equal(resources.saveStore.calls, 1)
  Assert.equal(reloads(), 0, "failed reset does not re-boot")
end

return { tests = T }
