-- FieldState composition contract: the state builds the FieldRuntime options
-- table explicitly from the documented runtime contract -- state-only options
-- (topologyProvider) never reach the runtime, while the development
-- product-mode flag crosses as a runtime option -- and update drives the
-- runtime directly, so a disposed state is a programming error, never a
-- silent no-op.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldState = require("game.src.game.FieldState")

local T = {}

-- A cache serving everything the presentation boot reads: the compiled font
-- definition and atlas the dialogue renderer opens, the generated field-UI
-- class (manifest + dialogue frame strip, signpost strip/wayfinding, Start
-- Menu surface, and Trainer Card front) the renderers draw, and the actor
-- index the presentation asset provider loads.
local function presentationCache()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  cache:write(FieldUiFixture.TRAINER_CARD_PATH, FieldUiFixture.cardBytes())
  cache:write(
    FieldActorCache.indexPath(),
    LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = { 0 } })
  )
  cache:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0))
  cache:write(FieldActorCache.atlasPath(0), FieldDialogueFixture.atlasBytes())
  return cache
end

-- Boot FieldState for real (the presentation resources are acquired against
-- the host) with FieldRuntime.new stubbed to capture the options table.
---@param options FieldStateOptions
---@param cache CacheFs? the presentation cache the stubbed runtime serves
---@return FieldState state
---@return table runtimeOptions
local function bootWithCapturedRuntimeOptions(options, cache)
  local captured
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _, runtimeOptions)
    captured = runtimeOptions
    return setmetatable({
      cacheFs = cache or presentationCache(),
      windowStyles = {
        resolve = function() end,
      },
      menuHost = {
        setScreenTopology = function() end,
        setPresentationMetrics = function() end,
      },
      actors = {
        visualRevision = function()
          return 0
        end,
        collectSpriteIds = function() end,
      },
      playerVisual = { spriteId = 0 },
      startMenuPlacement = nil,
      resizePresentation = function() end,
      dispose = function() end,
    }, FieldRuntime)
  end
  local ok, state = pcall(FieldState.new, "heartgold", nil, options)
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  return state, captured
end

-- The composition: FieldState constructs the signpost, Start Menu, and
-- Trainer Card renderers against the runtime's cache and sealed window style
-- registry, so their GPU resources are owned and released by the state
-- (never by controllers or the registry).
local function fieldStateOptions()
  return {
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
  }
end

-- Only the documented runtime contract crosses the state boundary: adding a
-- state-only option must not silently become a runtime option. The
-- development flag is a state-only presentation option (the playtest HUD and
-- developer binds), so it stays behind the boundary.
function T.only_documented_runtime_options_reach_the_runtime()
  local options = fieldStateOptions()
  options.resumeSave = true
  options.resetSave = false
  options.zoomConfig = { mode = "test" }
  options.development = true
  local state, captured = bootWithCapturedRuntimeOptions(options)
  Assert.deepEqual(captured, {
    resumeSave = true,
    resetSave = false,
    zoomConfig = { mode = "test" },
    presentation = true,
  })
  Assert.equal(state.development, true, "the state keeps the development flag for its own presentation")
  state:dispose()
end

function T.state_constructs_the_field_ui_renderers()
  local state = bootWithCapturedRuntimeOptions(fieldStateOptions())
  Assert.notNil(state.signpostRenderer, "the state constructs the signpost renderer")
  Assert.notNil(state.startMenuRenderer, "the state constructs the start menu renderer")
  Assert.notNil(state.trainerCardRenderer, "the state constructs the trainer card renderer")
  state:dispose()
end

function T.update_forwards_to_the_runtime()
  local updates = 0
  local state = setmetatable({
    runtime = {
      update = function()
        updates = updates + 1
      end,
      actors = {
        visualRevision = function()
          return 0
        end,
        collectSpriteIds = function() end,
      },
      playerVisual = { spriteId = 0 },
    },
    presentationActorAssets = {
      acquire = function() end,
      release = function() end,
    },
    _presentationSpriteRefs = {},
  }, FieldState)
  state:update(0.016)
  Assert.equal(updates, 1)
end

-- A presentation boot with a missing generated UI asset is a typed error: a
-- half-composed state is never returned. Each renderer's own release-on-
-- failure contract is unit-pinned; the state contract is that the typed
-- failure propagates from construction.
function T.state_construction_fails_typed_when_a_ui_asset_is_missing()
  local options = fieldStateOptions()
  local cardCache = presentationCache()
  cardCache:remove(FieldUiFixture.TRAINER_CARD_PATH)
  local cardErr = Assert.throws(function()
    bootWithCapturedRuntimeOptions(options, cardCache)
  end)
  Assert.isTrue(
    Errors.is(cardErr) and cardErr.code == "FIELD_UI_TRAINER_CARD_FRONT_MISSING",
    "a missing trainer card front is a typed construction failure: " .. tostring(cardErr)
  )

  local signpostCache = presentationCache()
  signpostCache:remove(FieldUiFixture.SIGNPOST_TILES_PATH)
  local signpostErr = Assert.throws(function()
    bootWithCapturedRuntimeOptions(options, signpostCache)
  end)
  Assert.isTrue(
    Errors.is(signpostErr) and signpostErr.code == "FIELD_UI_SIGNPOST_TILES_MISSING",
    "a missing signpost strip is a typed construction failure: " .. tostring(signpostErr)
  )
end

-- A disposed state (runtime cleared) has no zombie mode: driving it after
-- disposal is a programming error, not a silently ignored update.
function T.update_after_dispose_is_a_programming_error()
  local state = setmetatable({ runtime = nil }, FieldState)
  Assert.throws(function()
    state:update(0.016)
  end)
end

return { tests = T }
