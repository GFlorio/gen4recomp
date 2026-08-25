-- Shared, narrowly named helpers for acceptance scenarios that need a
-- source-valid Player House 1F opening-scene precondition: either drive the
-- source Mom scene to completion through production script execution, or
-- seed the documented post-opening scene variable for a test whose purpose
-- is an unrelated transition/lifecycle primitive. Neither helper disables
-- `MapInitScriptController` or the scheduler; they only drive/observe real
-- production state through existing public test seams.

local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local VAR_SCENE_PLAYERS_HOUSE_1F = FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F
local FLAGS = FieldScriptSymbols.flagsByName

local OpeningLifecycle = {
  VAR_SCENE_PLAYERS_HOUSE_1F = VAR_SCENE_PLAYERS_HOUSE_1F,
  MOM_GRANTED_FLAGS = {
    FLAGS.FLAG_GOT_BAG,
    FLAGS.FLAG_GOT_TRAINER_CARD,
    FLAGS.FLAG_GOT_SAVE_BUTTON,
    FLAGS.FLAG_GOT_OPTIONS_BUTTON,
  },
}

local function momFlagsGranted(world)
  for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
    if not world:isFlagSet(flag) then
      return false
    end
  end
  return true
end

-- Advance production dialogue/input until the source Player House 1F Mom
-- scene has released the field, granted its four progression flags, and
-- advanced `VAR_SCENE_PLAYERS_HOUSE_1F` to 1. Assumes `game` is already
-- positioned so the House 1F on-frame lifecycle can observe the source
-- fresh value 0 (an unset variable reads as 0).
---@param game table an AcceptanceHarness game
---@param maxTicks integer|nil
function OpeningLifecycle.completeOpeningHouseScene(game, maxTicks)
  local world = assert(game.runtime.scripts and game.runtime.scripts.worldState, "field world state unavailable")
  for _ = 1, maxTicks or 2400 do
    if game.runtime.errorText then
      error("the opening house scene faulted: " .. tostring(game.runtime.errorText))
    end
    local snapshot = game:snapshot()
    if snapshot.dialogue.modal then
      game.runtime:pressAction()
      game:step()
      game.runtime:releaseAction()
    else
      game:step()
    end
    if world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 1 and momFlagsGranted(world) and not game:snapshot().fieldLocked then
      return
    end
  end
  error("the source Player House Mom scene did not release the field")
end

-- Seed the documented post-opening source state directly, for a test whose
-- purpose is a transition/lifecycle primitive other than the Mom scene
-- itself (for example stairs). This never disables map-init evaluation.
--
-- Caution: New Bark's own on-frame rule also matches this same value (it is
-- the predicate for the friend/Marill scene). Only call this once `game` is
-- already resident on a map whose own generated rules do not match value 1
-- (Player House 1F only matches 0 and 3); do not call it while still on
-- MAP_NEW_BARK itself.
---@param game table an AcceptanceHarness game
function OpeningLifecycle.seedPostOpeningHouseState(game)
  game:setWorldState({ variable = VAR_SCENE_PLAYERS_HOUSE_1F, value = 1 })
end

-- The New Bark escort friend (source coords 688,392) and Marill sit on/near
-- the Elm landing/warp tile and are source-solid until the friend/Marill
-- on-frame scene runs and hides both actors (R10/C02: flags decide actor
-- presence), not a passability heuristic. Scenarios about the Elm
-- route/entrance-indicator effect rather than the scene itself seed its
-- documented outcome -- both hide flags -- directly, without running the
-- scripted scene or disabling any map-init evaluation.
---@param game table an AcceptanceHarness game
function OpeningLifecycle.settleNewBarkFriendScene(game)
  game:setWorldState({ flag = FLAGS.FLAG_HIDE_NEW_BARK_FRIEND })
  game:setWorldState({ flag = FLAGS.FLAG_HIDE_NEW_BARK_MARILL })
end

-- Read the canonical script id a generated on-frame-equal rule would start
-- for the given variable/value pair, straight from the runtime's own
-- generated map-init data. Returns nil if no such rule exists.
---@param runtime table a FieldRuntime
---@param variableId integer
---@param equals integer
---@return string|nil
function OpeningLifecycle.frameRuleScriptId(runtime, variableId, equals)
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.type == "on_frame_eq" then
      for _, rule in ipairs(group.rules) do
        if rule.variableId == variableId and rule.equals == equals then
          return rule.scriptId
        end
      end
    end
  end
  return nil
end

-- Read the canonical script id a fixed map-init lifecycle entry
-- (on_transition/on_resume/on_load) would start, straight from the
-- runtime's own generated map-init data. Returns nil if the map has no such
-- entry.
---@param runtime table a FieldRuntime
---@param lifecycle string "on_transition"|"on_resume"|"on_load"
---@return string|nil
function OpeningLifecycle.lifecycleScriptId(runtime, lifecycle)
  for _, group in ipairs(runtime.runtimeMap.fieldData.initScripts) do
    if group.type == lifecycle then
      return group.scriptId
    end
  end
  return nil
end

return OpeningLifecycle
