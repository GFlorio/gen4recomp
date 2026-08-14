-- The smallest UI-SFX player the production presentation needs for the
-- Start Menu effects: it resolves the semantic effect ids
-- (start_menu.open/select/cancel) to the generated field-UI WAV catalogue
-- and plays each through one explicitly acquired static audio source.
-- Finished sources are released by the fixed-sweep update; disposal stops
-- and releases every live source exactly once. Nothing here decodes ROM
-- audio: the producer rendered the effects offline and the generated
-- manifest owns the paths. LÖVE-facing interface module (love.audio only).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class UiSfxPlayerOptions
---@field cacheFs CacheFs the version-scoped private cache holding the generated sounds
---@field sounds table<string, { path: string }> the generated manifest sounds section (semantic id -> WAV path)
---@field audio table|nil love.audio namespace (injected in tests; defaults to love.audio)

---@class UiSfxPlayer
---@field _cacheFs CacheFs
---@field _sounds table<string, { path: string }>
---@field _audio table
---@field _sources table[] live acquired sources
local UiSfxPlayer = {}
UiSfxPlayer.__index = UiSfxPlayer

---@param opts UiSfxPlayerOptions
---@return UiSfxPlayer
function UiSfxPlayer.new(opts)
  assert(opts and opts.cacheFs and opts.cacheFs.read, "the UI-SFX player requires a CacheFs-shaped object")
  assert(type(opts.sounds) == "table", "the UI-SFX player requires the generated sound catalogue")
  local audio = opts.audio or (love and love.audio)
  assert(audio and type(audio.newSource) == "function", "the UI-SFX player requires an audio backend")
  return setmetatable({
    _cacheFs = opts.cacheFs,
    _sounds = opts.sounds,
    _audio = audio,
    _sources = {},
  }, UiSfxPlayer)
end

-- Acquires one static source for the effect's generated WAV and plays it.
-- The source stays owned by the player until the sweep observes it stopped
-- or dispose releases it. An unknown effect id is a programming fault; a
-- missing generated file is a typed cache failure -- never a silent drop.
---@param effectId string
function UiSfxPlayer:play(effectId)
  local sound = self._sounds[effectId]
  assert(sound ~= nil, "unknown UI effect " .. tostring(effectId))
  local bytes = self._cacheFs:read(sound.path)
  if bytes == nil then
    Errors.raise(
      FieldErrors.FIELD_UI_SOUND_MISSING,
      "generated UI effect file is missing: " .. tostring(sound.path),
      { path = sound.path, effectId = effectId }
    )
  end
  local source = self._audio:newSource(love.filesystem.newFileData(bytes, sound.path), "static")
  source:play()
  self._sources[#self._sources + 1] = source
end

-- One release sweep per update: a source that finished is stopped and
-- released exactly once; playing sources stay acquired.
function UiSfxPlayer:update()
  local remaining = {}
  for _, source in ipairs(self._sources) do
    if source:isStopped() then
      source:release()
    else
      remaining[#remaining + 1] = source
    end
  end
  self._sources = remaining
end

-- Stops and releases every live source exactly once; idempotent.
function UiSfxPlayer:dispose()
  for _, source in ipairs(self._sources) do
    source:stop()
    source:release()
  end
  self._sources = {}
end

return UiSfxPlayer
