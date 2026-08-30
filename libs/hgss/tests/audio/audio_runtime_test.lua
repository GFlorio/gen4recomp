-- AudioRuntime composes HGSS semantic audio over the NDS sound runtime
-- without requiring an application output device.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")

local T = {}

function T.composes_the_semantic_facade_and_pcm_renderer_without_love_output()
  local composition = AudioRuntime.compose({
    cacheFs = AudioFixture.readyCache(),
    outputRate = 32768,
  })

  Assert.notNil(composition.sound)
  Assert.equal(type(composition.sound.playMusic), "function")
  Assert.notNil(composition.renderer)
  Assert.equal(type(composition.renderer.render), "function")
end

return { tests = T }
