-- One production-composed opening journey. Host seams make time, audio output,
-- randomness, and save-root location deterministic; App and its game states stay real.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local GameSaveStore = require("libs.engine.src.GameSaveStore")
local SaveFs = require("libs.storage.src.SaveFs")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "product", "opening", "checkpoint" },
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
    Assert.notNil(App.state, "Oak must remain active until the profile is finalized")
    if App.state.runtime ~= nil then
      return
    end
    local view = App.state:view()
    if view.phase == "name_edit" then
      App.textinput("GOLD")
      App.keypressed("return")
    elseif interactive[view.phase] then
      press("a")
    else
      tick(1)
    end
  end
  error("Oak did not reach the opening field")
end

local function fieldStep(runtime, direction)
  runtime:press(direction)
  tick(2)
  runtime:release(direction)
  for _ = 1, 120 do
    tick(1)
    if runtime.player.motion == "idle" then
      return
    end
  end
  error("the production player did not finish moving " .. direction)
end

local function reachFirstFloor(runtime)
  for _ = 1, 3 do
    fieldStep(runtime, "west")
  end
  for _ = 1, 2 do
    fieldStep(runtime, "north")
  end
  Assert.equal(runtime.player.fieldX, 3)
  Assert.equal(runtime.player.fieldZ, 4)
  fieldStep(runtime, "west")
  for _ = 1, 240 do
    if runtime.runtimeMap.mapSymbol == "MAP_NEW_BARK_PLAYER_HOUSE_1F" then
      return
    end
    tick(1)
  end
  error("the production field did not complete the Player's House stair warp")
end

local function waitForMom(runtime)
  local world = runtime.scripts.worldState
  local flags = FieldScriptSymbols.flagsByName
  for _ = 1, 2400 do
    tick(1)
    if runtime.errorText then
      error(runtime.errorText)
    end
    if runtime.dialogue:isModal() then
      press("a")
    end
    if
      world:getVar(FieldScriptSymbols.variablesByName.VAR_SCENE_PLAYERS_HOUSE_1F) == 1
      and world:isFlagSet(flags.FLAG_GOT_BAG)
      and world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD)
      and world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON)
      and world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON)
      and not world:isFlagSet(flags.FLAG_GOT_POKEGEAR)
    then
      return
    end
  end
  error("the generated opening Mom event did not release the field")
end

local function openMenu(runtime)
  press("x")
  tick(2)
  local menu = runtime.applicationHost:status().menu
  Assert.notNil(menu, "the source start menu must open after Mom")
  return menu
end

local function choose(runtime, id)
  for _ = 1, 20 do
    local menu = runtime.applicationHost:status().menu
    for _, action in ipairs(menu.actions) do
      if action.id == id then
        press("a")
        tick(2)
        return
      end
    end
    press("dpdown")
    tick(1)
  end
  error("start menu action was not available: " .. id)
end

function T.tests.opening_reaches_and_restores_the_first_manual_checkpoint()
  local namespace = "acceptance/opening-product"
  local audio = FakeAudioOutput.new()
  local saveStore = GameSaveStore.new(SaveFs.global(isolatedBackend(namespace)))
  local original = { opts = App.opts, state = App.state, saveStore = App.saveStore, versionId = App.versionId }
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
    App.saveStore = saveStore
    App.state = nil
    App._bootMainMenu({ "heartgold" })
    Assert.equal(App.state:view().kind, "main_menu")
    ---@diagnostic disable-next-line: undefined-field
    Assert.equal(#saveStore:list(), 0)
    press("a")
    completeOak()
    local runtime = assert(App.state.runtime)
    Assert.equal(runtime.runtimeMap.mapSymbol, "MAP_NEW_BARK_PLAYER_HOUSE_2F")
    ---@diagnostic disable-next-line: undefined-field
    Assert.equal(#saveStore:list(), 0)
    reachFirstFloor(runtime)
    waitForMom(runtime)
    openMenu(runtime)
    choose(runtime, "vanilla.trainer_card")
    Assert.equal(runtime.applicationHost:status().applicationId, "trainer_card")
    press("b")
    tick(3)
    openMenu(runtime)
    choose(runtime, "vanilla.save")
    tick(3)
    ---@diagnostic disable-next-line: undefined-field
    local entries = saveStore:list()
    Assert.equal(#entries, 1)
    ---@diagnostic disable-next-line: undefined-field
    local checkpoint = assert(saveStore:load(entries[1].saveId))
    local savedMap = checkpoint.mapId
    App.setState(nil)
    App._bootMainMenu({ "heartgold" })
    Assert.equal(#App.state:view().items, 2)
    press("dpdown")
    press("a")
    tick(4)
    local continuedRuntime = assert(App.state.runtime, "Continue must enter the real FieldState")
    Assert.equal(continuedRuntime.runtimeMap.mapId, savedMap)
    App.draw()
    tick(4)
    App.draw()
    Assert.isTrue(continuedRuntime:destinationWorldPresentable(), "field remains presentable after entry draw")
    ---@diagnostic disable-next-line: undefined-field
    Assert.equal(#saveStore:list(), 1)
  end, debug.traceback)
  App.setState(nil)
  App.opts = original.opts
  App.state = original.state
  App.saveStore = original.saveStore
  App.versionId = original.versionId
  if not ok then
    error(err, 0)
  end
end

return T
