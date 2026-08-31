-- A fresh New Game must reach its first field runtime with the source
-- standard-init hide flags already active, so startup-hidden actors are
-- truly absent on first actor construction rather than repaired afterward.

local Assert = require("tests.support.Assert")
local App = require("app.src.App")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameSaveStore = require("libs.hgss.src.save.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
local SurfaceResolver = require("libs.hgss.src.field.SurfaceResolver")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "new-game", "startup", "product" },
  },
  tests = {},
}

local JOYSTICK = {
  getID = function()
    return 1
  end,
}

local function isolatedBackend(namespace)
  local fs = love.filesystem
  local function map(path)
    return namespace .. "/" .. path:gsub("^saves/", "")
  end
  return {
    write = function(_, path, data)
      return fs.write(map(path), data)
    end,
    read = function(_, path)
      return fs.read(map(path))
    end,
    getInfo = function(_, path)
      return fs.getInfo(map(path))
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(map(path))
    end,
    remove = function(_, path)
      return fs.remove(map(path))
    end,
    replace = function(_, source, destination)
      return os.rename(fs.getSaveDirectory() .. "/" .. map(source), fs.getSaveDirectory() .. "/" .. map(destination))
    end,
  }
end

local function press(button)
  App.gamepadpressed(JOYSTICK, button)
  App.gamepadreleased(JOYSTICK, button)
end

local function tick(frames)
  for _ = 1, frames do
    App.update(1 / 60)
  end
end

-- Skips through Oak by always confirming, without ever calling App.draw:
-- this scenario only needs the finalized field runtime, not the Oak
-- visuals, so no host draw call is ever attempted.
local function completeOak()
  local interactive = {
    greeting = true,
    oak_welcome = true,
    oak_world_inhabited = true,
    oak_live_alongside = true,
    oak_tell_about_yourself = true,
    gender_question = true,
    gender_select = true,
    gender_confirm = true,
    name_prompt = true,
    name_confirm = true,
    final_dialogue = true,
  }
  for _ = 1, 3600 do
    Assert.notNil(App.state and App.state.state, "Oak must remain active until the profile is finalized")
    if App.state.state.runtime ~= nil then
      return
    end
    local view = App.state.state:view()
    if view.phase == "name_edit" then
      App.textinput("GOLD")
      -- Navigate keyboard focus onto the virtual Confirm key before
      -- activating it, matching the one confirm-capable-device contract.
      App.keypressed("left")
      App.keypressed("return")
    elseif interactive[view.phase] then
      press("a")
    else
      tick(1)
    end
  end
  error("Oak did not reach the opening field")
end

function T.tests.fresh_new_game_hides_source_initial_actors_before_field_construction()
  local namespace = "acceptance/fresh-game-startup-flags"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  local original = { opts = App.opts, state = App.state }
  local ok, err = xpcall(function()
    ---@diagnostic disable-next-line: missing-fields
    App.opts = {
      test = false,
      actors = false,
      dev = false,
      saveStore = saveStore,
      oakIntroHost = {
        audioOutput = { audio = audio.audio, sound = audio.sound },
        clock = {
          nowLocal = function()
            return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
          end,
        },
        randomU32 = function()
          return 0x12345678
        end,
      },
    }
    App.state = nil
    App._bootMainMenu({ AcceptanceHarness.defaultVersion() })
    Assert.equal(App.state.state:view().kind, "main_menu")
    press("a")
    completeOak()

    local runtime = assert(App.state.state.runtime)
    for _ = 1, 240 do
      tick(1)
      if runtime:destinationWorldPresentable() then
        runtime:acknowledgeDestinationPresentation()
        break
      end
    end
    -- Inspected before any ordinary player input reaches the field: the
    -- source _std_init hide flags must already be true, and the hidden
    -- Player Room trophy actors already absent from the first map's live
    -- actor set, not repaired after occupancy is populated.
    Assert.equal(runtime.runtimeMap.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")

    local flags = FieldScriptSymbols.flagsByName
    local world = runtime.scripts.worldState
    local trophyFlags = {
      flags.FLAG_HIDE_PLAYERS_ROOM_BRONZE_TROPHY,
      flags.FLAG_HIDE_PLAYERS_ROOM_SILVER_TROPHY,
      flags.FLAG_HIDE_PLAYERS_ROOM_GOLD_TROPHY,
    }
    for _, flagId in ipairs(trophyFlags) do
      Assert.isTrue(world:isFlagSet(flagId), "trophy hide flag must already be set on first field construction")
    end
    Assert.isTrue(
      world:isFlagSet(flags.FLAG_HIDE_NEW_BARK_FRIEND),
      "New Bark friend hide flag must already be set on first field construction"
    )
    Assert.isTrue(
      world:isFlagSet(flags.FLAG_HIDE_NEW_BARK_MOM),
      "New Bark Mom hide flag must already be set on first field construction"
    )

    local trophySet = {}
    for _, flagId in ipairs(trophyFlags) do
      trophySet[flagId] = true
    end
    for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
      local eventFlag = actor.sourceEvent and actor.sourceEvent.eventFlag
      Assert.isFalse(
        eventFlag ~= nil and trophySet[eventFlag] == true,
        "a startup-hidden trophy actor must not exist in the active actor set: " .. actor.actorId
      )
    end

    -- Occupancy, not merely the actor list, must agree: at each hidden
    -- trophy's own source coordinate the manager holds no occupant at all,
    -- for the source reason that the actor is hidden -- never because
    -- collision independently exempted it (a warp/scriptId workaround would
    -- pass this same check for the wrong reason, so this asserts the
    -- resolved cell is entirely free).
    local runtimeMap = runtime.runtimeMap
    local objects = runtimeMap.fieldData.events.objects
    local trophyEventsChecked = 0
    for _, event in ipairs(objects) do
      if trophySet[event.eventFlag] == true then
        trophyEventsChecked = trophyEventsChecked + 1
        local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, event.x, event.z)
        local surface = SurfaceResolver.new(runtimeMap.terrain):resolve({
          localX = localX + FieldCoordinates.TILE_CENTER_OFFSET,
          localZ = localZ + FieldCoordinates.TILE_CENTER_OFFSET,
          currentY = event.y / 16,
        })
        Assert.isNil(
          runtime.actors:getAt(runtimeMap.mapId, { fieldX = event.x, fieldZ = event.z, surfaceId = surface.surfaceId }),
          "a startup-hidden trophy's own cell must hold no occupant"
        )
      end
    end
    Assert.isTrue(trophyEventsChecked > 0, "the fixture map must declare at least one hidden trophy event")
  end, debug.traceback)
  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  if not ok then
    error(err, 0)
  end
end

return T
