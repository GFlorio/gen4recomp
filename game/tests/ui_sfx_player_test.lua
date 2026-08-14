-- UiSfxPlayer contract tests: the smallest UI-SFX player the production
-- presentation needs for the three Start Menu effects (start_menu.open/
-- select/cancel). Every play acquires one static source explicitly through
-- the audio backend, finished sources are released by the update sweep, and
-- disposal releases every live source exactly once. The effect catalogue
-- comes from the generated field-UI manifest's sounds section (semantic
-- effect ids -> generated WAV paths); unknown ids and missing effect files
-- are loud programming/typed failures, never silent drops.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local UiSfxPlayer = require("game.src.game.UiSfxPlayer")

local T = {}

local function fakeAudio()
  local audio = {
    created = {},
  }
  function audio:newSource(data, mode)
    local source = {
      data = data,
      mode = mode,
      playing = false,
      stopped = false,
      released = false,
      releaseCalls = 0,
    }
    function source:play()
      self.playing = true
    end
    function source:stop()
      self.playing = false
      self.stopped = true
    end
    function source:isStopped()
      return self.stopped
    end
    function source:release()
      self.releaseCalls = self.releaseCalls + 1
      self.released = true
    end
    audio.created[#audio.created + 1] = source
    return source
  end
  return audio
end

local function cacheWithSound()
  local cache = FakeCache.new()
  cache:write("assets/generated/field/ui/sounds/start-menu-open.wav", "wav-bytes-open")
  cache:write("assets/generated/field/ui/sounds/start-menu-select.wav", "wav-bytes-select")
  cache:write("assets/generated/field/ui/sounds/start-menu-cancel.wav", "wav-bytes-cancel")
  return cache
end

local SOUNDS = {
  ["start_menu.open"] = {
    path = "assets/generated/field/ui/sounds/start-menu-open.wav",
    sampleRate = 22050,
    frameCount = 10,
  },
  ["start_menu.select"] = {
    path = "assets/generated/field/ui/sounds/start-menu-select.wav",
    sampleRate = 22077,
    frameCount = 10,
  },
  ["start_menu.cancel"] = {
    path = "assets/generated/field/ui/sounds/start-menu-cancel.wav",
    sampleRate = 22077,
    frameCount = 10,
  },
}

local function player(audio)
  return UiSfxPlayer.new({ cacheFs = cacheWithSound(), sounds = SOUNDS, audio = audio or fakeAudio() })
end

function T.construction_requires_the_sound_catalogue_and_audio_backend()
  Assert.throws(function()
    local missing = {} ---@type any
    UiSfxPlayer.new(missing)
  end)
  Assert.throws(function()
    local noSounds = { cacheFs = FakeCache.new() } ---@type any
    UiSfxPlayer.new(noSounds)
  end)
  Assert.throws(function()
    local noBackend = { cacheFs = FakeCache.new(), sounds = SOUNDS, audio = {} } ---@type any
    UiSfxPlayer.new(noBackend)
  end)
end

function T.play_acquires_one_static_source_and_plays_it()
  local audio = fakeAudio()
  local uiSfx = player(audio)
  uiSfx:play("start_menu.open")
  Assert.equal(#audio.created, 1)
  Assert.equal(audio.created[1].mode, "static")
  Assert.equal(audio.created[1].playing, true)
  Assert.equal(audio.created[1].released, false, "a playing source stays acquired")
end

function T.each_effect_resolves_its_generated_file()
  local audio = fakeAudio()
  local uiSfx = player(audio)
  uiSfx:play("start_menu.open")
  uiSfx:play("start_menu.select")
  uiSfx:play("start_menu.cancel")
  Assert.equal(#audio.created, 3)
  Assert.equal(audio.created[1].data:getFilename(), "assets/generated/field/ui/sounds/start-menu-open.wav")
  Assert.equal(audio.created[2].data:getFilename(), "assets/generated/field/ui/sounds/start-menu-select.wav")
  Assert.equal(audio.created[3].data:getFilename(), "assets/generated/field/ui/sounds/start-menu-cancel.wav")
end

function T.unknown_effect_ids_and_missing_files_are_loud()
  local audio = fakeAudio()
  local uiSfx = player(audio)
  Assert.throws(function()
    uiSfx:play("start_menu.unknown")
  end)
  local missing = UiSfxPlayer.new({
    cacheFs = FakeCache.new(),
    sounds = { ["start_menu.open"] = { path = "assets/generated/field/ui/sounds/missing.wav" } },
    audio = audio,
  })
  local err = Assert.throws(function()
    missing:play("start_menu.open")
  end) ---@type any
  Assert.isTrue(Errors.is(err), "a missing generated effect is a typed cache failure")
  Assert.equal(err.code, "FIELD_UI_SOUND_MISSING")
end

function T.the_update_sweep_releases_finished_sources_exactly_once()
  local audio = fakeAudio()
  local uiSfx = player(audio)
  uiSfx:play("start_menu.open")
  uiSfx:play("start_menu.select")
  local open, select = audio.created[1], audio.created[2]
  select:stop()
  uiSfx:update()
  Assert.equal(open.releaseCalls, 0, "a still-playing source stays acquired")
  Assert.equal(select.releaseCalls, 1, "a finished source is released by the sweep")
  uiSfx:update()
  Assert.equal(select.releaseCalls, 1, "the sweep never releases a source twice")
end

function T.dispose_releases_every_live_source_once()
  local audio = fakeAudio()
  local uiSfx = player(audio)
  uiSfx:play("start_menu.open")
  uiSfx:play("start_menu.select")
  local open, select = audio.created[1], audio.created[2]
  uiSfx:dispose()
  Assert.equal(open.releaseCalls, 1)
  Assert.equal(select.releaseCalls, 1)
  Assert.equal(open.playing, false, "dispose stops every live source")
  uiSfx:dispose()
  Assert.equal(open.releaseCalls, 1, "dispose is idempotent")
end

return { tests = T }
