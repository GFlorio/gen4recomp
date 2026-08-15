-- FieldMusicController: the field BGM policy component, separate from
-- GameSound. It decides WHAT should play from the generated field-map
-- record's day/night music block (the frozen map catalog's dayMusic/
-- nightMusic compiled into the field record); GameSound decides HOW it
-- plays. `mapHeaderMusic` selects the day or night reference of the
-- generated record through the injected day/night source, mirroring
-- FieldBGM_GetForMapHeader (pokeheartgold src/field_bgm.c selecting
-- MapHeader_GetDayMusicId vs _GetNightMusicId on IsNighttime). The
-- controller is stateless: the map is an argument, so the runtime
-- re-selects after a map swap without controller state to update.
-- ResetBGM's "play map-header music" wiring lives in the composition.

---@class FieldMusicController
---@field private _dayNight fun(): string
local FieldMusicController = {}
FieldMusicController.__index = FieldMusicController

---@param opts { dayNight: fun(): string }
---@return FieldMusicController
function FieldMusicController.new(opts)
  assert(opts and type(opts.dayNight) == "function", "FieldMusicController requires a day/night source")
  return setmetatable({
    _dayNight = opts.dayNight,
  }, FieldMusicController)
end

-- The day/night map-header music reference (a "SEQ_*" symbol), or nil when
-- the generated record carries no music block (the map has no BGM).
---@param runtimeMap table
---@return string?
function FieldMusicController:mapHeaderMusic(runtimeMap)
  local music = runtimeMap and runtimeMap.fieldData and runtimeMap.fieldData.music
  if type(music) ~= "table" then
    return nil
  end
  local reference = music[self._dayNight()]
  if type(reference) ~= "string" then
    return nil
  end
  return "SEQ_" .. reference
end

return FieldMusicController
