-- FieldMusicController contract: the field BGM policy component, separate
-- from GameSound. It decides WHAT should play from the generated field-map
-- record's day/night music block; GameSound decides HOW. The day/night source
-- is injectable (the production composition supplies the wall-clock default);
-- the controller is stateless -- the map is an argument, so the runtime can
-- re-select after a map swap without controller state to update.
-- `mapHeaderMusic` selects the day or night reference of the generated
-- record; `effectiveMusic` is the explicit layer that initially equals the
-- map-header result (surfing/save overrides are not modeled yet but the layer
-- is preserved). ResetBGM's "play map-header music, never effective" wiring
-- lives in the composition and the acceptance scenarios.

local Assert = require("tests.support.Assert")
local FieldMusicController = require("libs.engine.src.audio.FieldMusicController")

local T = {}

local function mapWith(music)
  return { fieldData = { music = music } }
end

local function day()
  return "day"
end

local function night()
  return "night"
end

function T.map_header_music_selects_the_day_branch_from_the_generated_record()
  local controller = FieldMusicController.new({ dayNight = day })
  Assert.equal(controller:mapHeaderMusic(mapWith({ day = "GS_DAY", night = "GS_NIGHT" })), "SEQ_GS_DAY")
end

function T.map_header_music_selects_the_night_branch_from_the_generated_record()
  local controller = FieldMusicController.new({ dayNight = night })
  Assert.equal(controller:mapHeaderMusic(mapWith({ day = "GS_DAY", night = "GS_NIGHT" })), "SEQ_GS_NIGHT")
end

function T.effective_music_is_an_explicit_layer_equal_to_map_header_music_initially()
  local controller = FieldMusicController.new({ dayNight = night })
  local map = mapWith({ day = "GS_DAY", night = "GS_NIGHT" })
  Assert.equal(controller:effectiveMusic(map), controller:mapHeaderMusic(map))
end

function T.a_record_without_music_reports_none()
  local controller = FieldMusicController.new({ dayNight = day })
  Assert.isNil(controller:mapHeaderMusic(mapWith(nil)))
  Assert.isNil(controller:mapHeaderMusic({}))
  Assert.isNil(controller:effectiveMusic(mapWith(nil)))
end

function T.construction_requires_the_day_night_source()
  Assert.throws(function()
    FieldMusicController.new({})
  end)
  Assert.throws(function()
    FieldMusicController.new({ dayNight = "day" } --[[@as table]])
  end)
end

return { tests = T }
