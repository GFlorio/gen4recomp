-- FieldState disposal contract. The single general disposal hook persists the
-- field session when one is live, releases every owned resource exactly once,
-- and is a no-op on repeat calls, so state replacement and application quit
-- can never double-save or double-release.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldState = require("game.src.game.FieldState")

local T = {}

-- A fake resource whose named method records how often it is called.
---@param method "dispose"|"release"|"save"
local function fakeResource(method)
  local resource = {}
  resource[method] = function(self)
    self.calls = (self.calls or 0) + 1
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
    saveStore = fakeResource("save"),
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
  Assert.isNil(state.session)
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
  local state = setmetatable({ errorText = "boom" }, FieldState)
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

return T
