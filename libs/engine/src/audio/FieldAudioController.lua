-- FieldAudioController: the stateful field-audio policy service. Owns the
-- current field map audio record, effective field-music selection (day/night
-- + flag overrides + traversal override + persisted override), soundplate
-- selection and environmental audio state, and delegating the script audio
-- facade (play, stop, playMusic, etc.) to the composed GameSound instance.
--
-- Field-music policy:
-- 1. mapHeaderMusic(): day/night selection + flag-based map override
-- 2. effectiveMusic(): traversal override > map-header > persisted override
-- 3. resetMusic(): map-header only (ignores traversal and persisted)
--
-- Soundplate/environment policy:
-- - Selection: iterate source-order records, keep last (highest) match
-- - Active gate: test selected plate's disabledWhenFlag (no fallback if disabled)
-- - Volume ramps: BGM duck + ambient moves via GameSound:moveSequenceVolume
-- - Exit: fade-stop environment, restore BGM to level 128

local Errors = require("libs.errors.src.Errors")

---@class FieldAudioController
---@field private _sound GameSound
---@field private _provider AudioAssetProvider
---@field private _eventState any
---@field private _player any
---@field private _dayNight fun(): "day"|"night"
---@field private _fieldDataForMap fun(mapId: integer|string): any
---@field private _currentMap any
---@field private _fieldMusic integer|string|nil
---@field private _musicOverride integer|string|nil
---@field private _traversal "walking"|"surfing"
---@field private _environment any

local FieldAudioController = {}
FieldAudioController.__index = FieldAudioController

---@param opts { sound: GameSound, provider: AudioAssetProvider, eventState: any, player: any, dayNight: fun(): "day"|"night", fieldDataForMap: fun(mapId: integer|string): any }
---@return FieldAudioController
function FieldAudioController.new(opts)
  assert(
    opts and opts.sound and opts.provider and opts.eventState and opts.player and opts.dayNight and opts.fieldDataForMap,
    "FieldAudioController requires sound, provider, eventState, player, dayNight, and fieldDataForMap"
  )
  return setmetatable({
    _sound = opts.sound,
    _provider = opts.provider,
    _eventState = opts.eventState,
    _player = opts.player,
    _dayNight = opts.dayNight,
    _fieldDataForMap = opts.fieldDataForMap,
    _currentMap = nil,
    _fieldMusic = nil,
    _musicOverride = nil,
    _traversal = "walking",
    _environment = nil,
  }, FieldAudioController)
end

-- Returns the map-header music reference: day/night selection + flag-based override.
-- Does NOT apply traversal or persisted overrides (those are part of effectiveMusic).
-- Resolves string symbols to numeric IDs using the provider.
-- @param fieldData optional field data; if omitted, uses current map's data
---@return integer|string|nil
function FieldAudioController:mapHeaderMusic(fieldData)
  if fieldData == nil then
    if self._currentMap == nil then
      return nil
    end
    fieldData = self._currentMap.fieldData
  end
  if fieldData == nil or fieldData.music == nil then
    return nil
  end

  -- Start with day/night selection
  local dayNight = self._dayNight()
  local music = fieldData.music
  local sequence = music[dayNight]

  -- Apply flag-based map overrides in source order
  if music.flagOverrides ~= nil then
    for _, override in ipairs(music.flagOverrides) do
      if self._eventState:isFlagSet(override.flagId) then
        sequence = override.sequence
        break
      end
    end
  end

  -- Resolve string symbol to numeric ID
  if sequence ~= nil and type(sequence) == "string" then
    sequence = self._provider:sequence(sequence).id
  end

  return sequence
end

-- Returns the effective field music: traversal > map-header > persisted override
-- Returns numeric ID (resolves persisted override string if needed).
---@return integer|nil
function FieldAudioController:effectiveMusic()
  -- Check traversal overrides first (highest precedence)
  if self._currentMap ~= nil and self._currentMap.fieldData and self._currentMap.fieldData.music then
    local music = self._currentMap.fieldData.music
    if music.traversalOverrides ~= nil then
      for _, trav in ipairs(music.traversalOverrides) do
        if trav.traversal == self._traversal then
          -- Check the gating flag
          if trav.unlessFlagId == nil or not self._eventState:isFlagSet(trav.unlessFlagId) then
            -- Resolve string symbol to numeric ID
            local sequence = trav.sequence
            if type(sequence) == "string" then
              sequence = self._provider:sequence(sequence).id
            end
            return sequence
          end
        end
      end
    end
  end

  -- Map-header music
  local header = self:mapHeaderMusic()

  -- Persisted override (lowest precedence)
  if self._musicOverride ~= nil then
    local override = self._musicOverride
    if type(override) == "string" then
      override = self._provider:sequence(override).id
    end
    return override
  end

  return header
end

-- Plays the map-header music (not effective music; ignores traversal and persisted overrides).
-- This is the source ResetBGM behavior.
function FieldAudioController:resetMusic()
  local reference = self:mapHeaderMusic()
  if reference == nil then
    self._sound:stopMusic()
    return
  end
  self._sound:playMusic(reference)
end

-- Sets the persisted field-music override (stores original string or numeric form)
---@param sequenceRef integer|string|nil
function FieldAudioController:setMusicOverride(sequenceRef)
  self._musicOverride = sequenceRef
end

-- Clears the persisted override
function FieldAudioController:clearMusicOverride()
  self._musicOverride = nil
end

-- Returns the current persisted override (string symbol or numeric ID)
---@return integer|string|nil
function FieldAudioController:musicOverride()
  return self._musicOverride
end

-- Sets the traversal mode (walking or surfing)
---@param mode "walking"|"surfing"
function FieldAudioController:setTraversalMode(mode)
  assert(mode == "walking" or mode == "surfing", "traversal mode must be 'walking' or 'surfing'")
  self._traversal = mode
end

-- Enters a map and optionally plays the effective music
-- Options: { clearMusicOverride, restoredMusicOverride, play }
---@param runtimeMap any
---@param options table|nil
function FieldAudioController:enterMap(runtimeMap, options)
  options = options or {}

  self._currentMap = runtimeMap

  if options.clearMusicOverride then
    self._musicOverride = nil
  elseif options.restoredMusicOverride ~= nil then
    self._musicOverride = options.restoredMusicOverride
  end

  -- Update field music (base map-header, used for soundplate bank selection)
  self._fieldMusic = self:mapHeaderMusic()

  -- Clear environment when entering new map
  if self._environment ~= nil then
    -- Fade-stop the environment if it was active
    if self._currentMap.fieldData and self._currentMap.fieldData.soundplates then
      -- Will be handled in updateField next call
    end
    self._environment = nil
  end

  -- Play effective music if requested
  if options.play then
    local effective = self:effectiveMusic()
    if effective == nil then
      self._sound:stopMusic()
    else
      self._sound:playMusic(effective)
    end
  end
end

-- Pre-fade current BGM if destination map-header differs
-- This is the source FieldBGM_TryFadeIn behavior on warp start
---@param destinationMapId integer|string
function FieldAudioController:beginWarp(destinationMapId)
  local destData = self._fieldDataForMap(destinationMapId)
  if destData == nil then
    return
  end

  -- Get destination map-header music
  local destFieldData = { music = destData.music, soundplates = destData.soundplates }
  local destMusic = self:mapHeaderMusic(destFieldData)

  -- If current BGM differs, start fade to 0 over 40 sound frames
  local currentMusic = self._sound:currentMusic()
  if destMusic ~= currentMusic then
    -- Fade the current BGM if one is playing
    if currentMusic ~= nil and not self._sound:isMusicFadeActive() then
      self._sound:fadeMusicOut({ target = 0, durationTicks = 40 })
    end
  end
end

-- Updates field-policy state on 30 Hz ticks: soundplate selection
function FieldAudioController:updateField()
  if self._currentMap == nil or self._currentMap.fieldData == nil then
    return
  end

  local fieldData = self._currentMap.fieldData
  if fieldData.soundplates == nil or #fieldData.soundplates == 0 then
    -- No soundplates; clear environment if active
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
    return
  end

  -- Get player land-local coordinates (modulo 32)
  local playerX = self._player.x or 0
  local playerZ = self._player.z or 0
  local localX = playerX % 32
  local localZ = playerZ % 32

  -- Iterate soundplates in source order, keep last matching
  local selectedPlateIndex = nil
  for i, plate in ipairs(fieldData.soundplates) do
    -- Check inclusive rectangle match: x <= localX <= xBounds and z <= localZ <= zBounds
    if localX >= plate.x and localX <= plate.xBounds and localZ >= plate.z and localZ <= plate.zBounds then
      selectedPlateIndex = i
    end
  end

  -- If a plate is selected, check its active flag
  if selectedPlateIndex ~= nil then
    local plate = fieldData.soundplates[selectedPlateIndex]

    -- Test disabled flag (no fallback if disabled)
    if plate.disabledWhenFlag ~= nil and self._eventState:isFlagSet(plate.disabledWhenFlag) then
      -- Plate is disabled; deactivate environment
      if self._environment ~= nil then
        self:_deactivateSoundplate()
      end
      return
    end

    -- Activate/update this soundplate
    if self._environment == nil or self._environment.plateIndex ~= selectedPlateIndex then
      self:_activateSoundplate(plate, selectedPlateIndex)
    end
  else
    -- No matching plate; deactivate environment
    if self._environment ~= nil then
      self:_deactivateSoundplate()
    end
  end
end

-- Activates a soundplate: starts the environment sequence and schedules volume moves
---@param plate table
---@param plateIndex integer
function FieldAudioController:_activateSoundplate(plate, plateIndex)
  -- If there's an old environment, deactivate it first
  if self._environment ~= nil then
    self:_deactivateSoundplate()
  end

  -- Start the environment sequence
  local sequence = self._provider:sequence(plate.sequence)

  -- If useFieldMusicBank, use field-BGM's bank; otherwise use sequence's own bank
  if plate.useFieldMusicBank and self._fieldMusic ~= nil then
    local fieldBgm = self._provider:sequence(self._fieldMusic)
    local fieldBank = self._provider:bank(fieldBgm.bankId)
    self._player:play(sequence, fieldBank)
  else
    local bank = self._provider:bank(sequence.bankId)
    self._player:play(sequence, bank)
  end

  -- Record environment state
  self._environment = {
    sequence = sequence.id,
    plateIndex = plateIndex,
  }

  -- Schedule volume moves if targets are specified
  if plate.bgmTarget ~= nil and self._fieldMusic ~= nil then
    -- Move base field-BGM fader to bgmTarget over 15 frames
    self._sound:moveSequenceVolume(self._fieldMusic, plate.bgmTarget, 15)
  end

  if plate.ambientTarget ~= nil then
    -- Move environment sequence fader to ambientTarget over 5 frames
    self._sound:moveSequenceVolume(plate.sequence, plate.ambientTarget, 5)
  end
end

-- Deactivates the current soundplate: fades environment and restores BGM
function FieldAudioController:_deactivateSoundplate()
  if self._environment == nil then
    return
  end

  -- Fade-stop the environment sequence over 10 frames
  self._sound:stopSequenceWithFade(self._environment.sequence, 10)

  -- Restore base field-BGM fader to 128 over 15 frames
  if self._fieldMusic ~= nil then
    self._sound:moveSequenceVolume(self._fieldMusic, 128, 15)
  end

  self._environment = nil
end

-- Delegates to GameSound:updateSoundFrame() for 60 Hz sound-frame clock
function FieldAudioController:updateSoundFrame()
  self._sound:updateSoundFrame()
end

-- Script facade delegation to GameSound

function FieldAudioController:play(idOrSymbol)
  self._sound:play(idOrSymbol)
end

function FieldAudioController:stop(idOrSymbol)
  self._sound:stop(idOrSymbol)
end

function FieldAudioController:isEffectPlaying(idOrSymbol)
  return self._sound:isEffectPlaying(idOrSymbol)
end

function FieldAudioController:playMusic(idOrSymbol)
  self._sound:playMusic(idOrSymbol)
end

function FieldAudioController:stopMusic()
  self._sound:stopMusic()
end

function FieldAudioController:currentMusic()
  return self._sound:currentMusic()
end

function FieldAudioController:playFanfare(idOrSymbol)
  self._sound:playFanfare(idOrSymbol)
end

function FieldAudioController:isFanfarePlaying()
  return self._sound:isFanfarePlaying()
end

function FieldAudioController:fadeMusicOut(spec)
  self._sound:fadeMusicOut(spec)
end

function FieldAudioController:fadeMusicIn(spec)
  self._sound:fadeMusicIn(spec)
end

function FieldAudioController:isMusicFadeActive()
  return self._sound:isMusicFadeActive()
end

function FieldAudioController:temporaryMusic(idOrSymbol)
  self._sound:temporaryMusic(idOrSymbol)
end

function FieldAudioController:playCry(species, form)
  self._sound:playCry(species, form)
end

function FieldAudioController:isCryFinished()
  return self._sound:isCryFinished()
end

-- Internal field-policy helpers (not script-facing)

function FieldAudioController:moveSequenceVolume(idOrSymbol, target, durationFrames)
  self._sound:moveSequenceVolume(idOrSymbol, target, durationFrames)
end

function FieldAudioController:stopSequenceWithFade(idOrSymbol, durationFrames)
  self._sound:stopSequenceWithFade(idOrSymbol, durationFrames)
end

return FieldAudioController
