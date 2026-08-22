-- Product New Game acceptance: the real Main Menu and App compose Oak from
-- the selected generated cache without a test Oak factory.

local Assert = require("tests.support.Assert")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FakeCache = require("tests.support.FakeCache")
local App = require("game.src.game.App")
local GameSaveStore = require("libs.engine.src.GameSaveStore")
local OakIntroState = require("game.src.game.OakIntroState")
local SaveFs = require("libs.storage.src.SaveFs")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "oak", "product", "composition" },
  },
  tests = {},
}

local function hostSeams()
  local image = {}
  function image:getWidth()
    return 256
  end
  function image:getHeight()
    return 192
  end
  function image:setFilter() end
  function image:release() end

  local graphics = {
    newQuad = function()
      return {}
    end,
  }
  local audio = FakeAudioOutput.new()
  return {
    graphics = graphics,
    imageLoader = function()
      return image
    end,
    audioOutput = { audio = audio.audio, sound = audio.sound },
    clock = {
      nowLocal = function()
        return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
      end,
    },
    randomU32 = function()
      return 0x12345678
    end,
    textInputHost = { setTextInput = function() end },
  }
end

function T.tests.new_game_enters_production_oak_without_a_factory()
  local original = {
    opts = App.opts,
    state = App.state,
    saveStore = App.saveStore,
    versionId = App.versionId,
  }
  local store = GameSaveStore.new(SaveFs.global(FakeCache.new()))
  App.opts = { saveStore = store, oakIntroHost = hostSeams() }
  App.saveStore = store
  App.state = nil
  App.versionId = nil

  local ok, err = xpcall(function()
    App._bootMainMenu({ "heartgold" })
    App.keypressed("return")
    Assert.equal(getmetatable(App.state).__index, OakIntroState)
    Assert.equal(App.state.controller:candidate().saveId, "save-00000001")
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
