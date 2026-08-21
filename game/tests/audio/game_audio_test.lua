-- GameAudio composition tests cover the shared production wiring and its
-- failure ownership boundary. AudioFixture supplies a generated-cache-shaped
-- input; host output is replaced only at the true sink boundary.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local GameAudio = require("game.src.game.audio.GameAudio")
local GameSound = require("libs.engine.src.audio.GameSound")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")

local T = {}

function T.a_failure_after_sink_creation_releases_the_sink_once()
  local cacheFs = AudioFixture.readyCache()
  local originalSoundNew = GameSound.new
  local originalSinkNew = LoveAudioSink.new
  local releaseCalls = 0

  rawset(GameSound, "new", function()
    error("injected game sound construction failure")
  end)
  rawset(LoveAudioSink, "new", function()
    return {
      release = function()
        releaseCalls = releaseCalls + 1
      end,
    }
  end)

  local ok, err = pcall(function()
    GameAudio.compose({
      cacheFs = cacheFs,
      outputRate = 32768,
      outputHost = { audio = {}, sound = {} },
    })
  end)

  rawset(GameSound, "new", originalSoundNew)
  rawset(LoveAudioSink, "new", originalSinkNew)

  Assert.isFalse(ok, "a later composition failure must propagate")
  Assert.equal(releaseCalls, 1, "a sink acquired before failure is released exactly once")
  Assert.isTrue(
    type(err) == "string" and string.find(err, "injected game sound construction failure", 1, true) ~= nil,
    "the original construction failure must propagate"
  )
end

function T.core_composition_exposes_the_shared_engine_objects()
  local core = GameAudio.compose({
    cacheFs = AudioFixture.readyCache(),
    outputRate = 32768,
  })
  Assert.notNil(core.provider)
  Assert.notNil(core.mixer)
  Assert.notNil(core.player)
  Assert.notNil(core.cry)
  Assert.notNil(core.sound)
  Assert.isNil(core.sink)
end

return { tests = T }
