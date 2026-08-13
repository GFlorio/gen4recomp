-- FieldState composition contract: the state builds the FieldRuntime options
-- table explicitly from the documented runtime contract -- state-only options
-- (development, topologyProvider) never reach the runtime -- and update drives
-- the runtime directly, so a disposed state is a programming error, never a
-- silent no-op.

local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldState = require("game.src.game.FieldState")

local T = {}

-- A cache serving everything the presentation boot reads: the compiled font
-- definition and atlas the dialogue renderer opens and the actor index the
-- presentation asset provider loads.
local function presentationCache()
  local cache = FieldDialogueFixture.cacheWithFont()
  cache:write(FieldActorCache.indexPath(), LuaWriter.encode({ schema = FieldActorCache.INDEX_SCHEMA, spriteIds = {} }))
  return cache
end

-- Boot FieldState for real (the presentation resources are acquired against
-- the host) with FieldRuntime.new stubbed to capture the options table.
---@param options FieldStateOptions
---@return FieldState state
---@return table runtimeOptions
local function bootWithCapturedRuntimeOptions(options)
  local captured
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, _, runtimeOptions)
    captured = runtimeOptions
    return setmetatable({
      cacheFs = presentationCache(),
      menuHost = {
        setScreenTopology = function() end,
        setPresentationMetrics = function() end,
      },
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

-- Only the documented runtime contract crosses the state boundary: adding a
-- state-only option must not silently become a runtime option.
function T.only_documented_runtime_options_reach_the_runtime()
  local state, captured = bootWithCapturedRuntimeOptions({
    resumeSave = true,
    resetSave = false,
    zoomConfig = { mode = "test" },
    development = true,
    topologyProvider = function()
      ---@type ScreenTopology
      return nil
    end,
  })
  Assert.deepEqual(captured, {
    resumeSave = true,
    resetSave = false,
    zoomConfig = { mode = "test" },
    presentation = true,
  })
  state:dispose()
end

function T.update_forwards_to_the_runtime()
  local updates = 0
  local state =
    setmetatable({ runtime = {
      update = function()
        updates = updates + 1
      end,
    } }, FieldState)
  state:update(0.016)
  Assert.equal(updates, 1)
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
