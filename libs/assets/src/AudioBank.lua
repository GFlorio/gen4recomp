-- Validator for the derived audio bank asset: numeric and symbolic identity,
-- its wave-archive slot map, and a program-keyed instruments map. Instrument
-- kinds are the semantic direct/key_split/drum_set (never SBNK record
-- types). Playable leaves have the common shape {generator, originalKey,
-- envelope, pan}: sample voices add the content-address key, square voices
-- carry the discrete DS PSG duty index 0..7 (never a float fraction), and
-- square/noise voices carry their source original key like every other leaf.
-- The exact silent DUMMY leaf is the sole exception to that playable shape.
-- `validate` and `sampleKeys` share one internal leaf traversal (walkVoices)
-- that owns the instruments-map grammar; validation additionally enforces the
-- strict leaf grammar, while `sampleKeys` collects the content-address keys
-- every voice references through a walk that trusts voice fields. It returns
-- nil when the instrument shape is malformed, so a malformed shape can never
-- be mistaken for "no sample references" (AudioCacheValidator relies on it).
-- `selectVoice` is the semantic leaf selection by MIDI key (key-split range
-- match / drum-set index), the helper the runtime player calls after it
-- resolves the clamped transposed key.

local AudioBank = {}

---@class AudioBank
---@field SCHEMA string
---@field sampleKeys fun(bank: table): string[]?
---@field selectVoice fun(instrument: table, midiKey: integer): table?
---@field validate fun(bank: table): true
---@class AudioBank.Instrument
---@field kind string
---@field voice table?
---@field ranges table[]?
---@field lowKey integer?
---@field highKey integer?
---@field voices table[]?

---@class AudioBank.Range
---@field lowKey integer
---@field highKey integer
---@field voice table

---@class AudioBank.Voice
---@field kind string?
---@field generator table
---@field originalKey integer
---@field envelope table
---@field pan integer

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.assets.src.AudioErrors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioBank.SCHEMA = Contract.audio.bankSchema

---@param context table
local function fail(context)
  Errors.raise(AudioErrors.AUDIO_BANK_INVALID, "malformed audio bank asset", context)
end

---@param value number
---@param low number
---@param high number
---@return boolean
local function isIntegerInRange(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

---@param value number
---@return boolean
local function isKey(value)
  return isIntegerInRange(value, 0, 0x7F)
end

-- Walks every leaf voice of an instruments map, calling
-- `visit(instrument, voice)`; returning false from the visit aborts the walk
-- with a falsy result, so a malformed shape is a failed walk, never an empty
-- reference set. The walk owns the instruments-map grammar (nonnegative
-- integer program keys, known kinds, key-split range keys and order,
-- drum-set bounds with full key coverage); leaf field validity is the
-- validator's own strict check.
---@param instruments table<integer, AudioBank.Instrument>
---@param visit fun(instrument: AudioBank.Instrument, voice: table): boolean
---@return boolean
local function walkVoices(instruments, visit)
  if type(instruments) ~= "table" or next(instruments) == nil then
    return false
  end
  for key, instrument in pairs(instruments) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 or type(instrument) ~= "table" then
      return false
    end
    if instrument.kind == "direct" then
      if type(instrument.voice) ~= "table" or not visit(instrument, instrument.voice) then
        return false
      end
    elseif instrument.kind == "key_split" then
      if not Validate.isArray(instrument.ranges) or #instrument.ranges == 0 then
        return false
      end
      -- The SDK split-key walk drops leaves with a smaller-low split key, so
      -- compiler output is an ordered, non-overlapping partition: every
      -- range's lowKey must be strictly above the previous range's highKey.
      local previousHigh = nil ---@type integer?
      local ranges = instrument.ranges ---@type AudioBank.Range[]
      for _, range in ipairs(ranges) do
        if
          type(range) ~= "table"
          or not isKey(range.lowKey)
          or not isKey(range.highKey)
          or range.lowKey > range.highKey
          or (previousHigh ~= nil and range.lowKey <= previousHigh)
        then
          return false
        end
        previousHigh = range.highKey
        if type(range.voice) ~= "table" or not visit(instrument, range.voice) then
          return false
        end
      end
    elseif instrument.kind == "drum_set" then
      if not isKey(instrument.lowKey) or not isKey(instrument.highKey) or instrument.lowKey > instrument.highKey then
        return false
      end
      if
        not Validate.isArray(instrument.voices)
        or #instrument.voices ~= instrument.highKey - instrument.lowKey + 1
      then
        return false
      end
      for _, voice in ipairs(instrument.voices) do
        if type(voice) ~= "table" or not visit(instrument, voice) then
          return false
        end
      end
    else
      return false
    end
  end
  return true
end

-- The content-address keys every voice of `bank` references, or nil when the
-- instrument shape is malformed. The walk trusts voice fields (the caller
-- validates first): it only fails on instrument-map shapes, so validation and
-- reference resolution cannot drift apart.
---@param bank table
---@return string[]|nil
function AudioBank.sampleKeys(bank)
  if type(bank) ~= "table" then
    return nil
  end
  local keys = {} ---@type string[]
  local seen = {} ---@type table<string, boolean>
  local ok = walkVoices(bank.instruments, function(_, voice)
    local generator = voice.generator ---@type table
    if type(generator) == "table" and generator.kind == "sample" then
      local key = generator.sample ---@type string
      if not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end
    return true
  end)
  if not ok then
    return nil
  end
  return keys
end

-- The leaf voice an instrument plays for a MIDI key: direct is the single
-- voice, key_split matches the key's range, drum_set indexes voices by key
-- within its low/high bounds. Returns nil for a key with no voice (the note
-- is silent but still gates the track). The caller resolves the clamped
-- transposed MIDI key before calling -- the NNS TrackPlayNote path clamps
-- midiKey and SND_ReadInstData selects the leaf by it, so instrument
-- selection always runs on the transposed key, never the source note key.
---@param instrument AudioBank.Instrument
---@param midiKey integer
---@return table?
function AudioBank.selectVoice(instrument, midiKey)
  if instrument.kind == "direct" then
    if instrument.voice.kind == "dummy" then
      return nil
    end
    return instrument.voice
  end
  if instrument.kind == "key_split" then
    for _, range in ipairs(instrument.ranges) do
      if midiKey >= range.lowKey and midiKey <= range.highKey then
        if range.voice.kind == "dummy" then
          return nil
        end
        return range.voice
      end
    end
    return nil
  end
  if instrument.kind == "drum_set" then
    if midiKey < instrument.lowKey or midiKey > instrument.highKey then
      return nil
    end
    local voice = instrument.voices[midiKey - instrument.lowKey + 1]
    if voice.kind == "dummy" then
      return nil
    end
    return voice
  end
  assert(false, "unknown instrument kind")
end

---@param voice table
local function validateVoice(voice)
  if type(voice) ~= "table" then
    fail({ field = "voice" })
  end
  if voice.kind == "dummy" then
    local fields = voice ---@type table<string, unknown>
    for key in pairs(fields) do
      if key ~= "kind" then
        fail({ field = "voice" })
      end
    end
    return
  end
  if voice.kind ~= nil then
    fail({ field = "voice.kind" })
  end
  local generator = voice.generator ---@type table
  if type(generator) ~= "table" then
    fail({ field = "voice.generator" })
  end
  -- The common voice shape: the source original key exists for every
  -- generator kind, including square/noise leaves.
  if not isKey(voice.originalKey) then
    fail({ field = "voice.originalKey" })
  end
  if generator.kind == "sample" then
    if not Validate.isSha1Key(generator.sample) then
      fail({ field = "voice.generator.sample" })
    end
  elseif generator.kind == "square" then
    -- The discrete DS PSG duty index 0..7 (GBATEK): an integer, never a
    -- float fraction; index 7 is the hardware all-LOW special pattern.
    if not isIntegerInRange(generator.duty, 0, 7) then
      fail({ field = "voice.generator.duty" })
    end
  elseif generator.kind == "noise" then
    -- bare generator: no parameters
  else
    fail({ field = "voice.generator.kind" })
  end
  local envelope = voice.envelope ---@type table
  if type(envelope) ~= "table" then
    fail({ field = "voice.envelope" })
  end
  for _, field in ipairs({ "attack", "decay", "sustain", "release" }) do
    if not isIntegerInRange(envelope[field], 0, 0x7F) and not (field == "release" and envelope[field] == 0xFF) then
      fail({ field = "voice.envelope." .. field })
    end
  end
  if not isIntegerInRange(voice.pan, 0, 0x7F) then
    fail({ field = "voice.pan" })
  end
end

---@param bank table
---@return true
function AudioBank.validate(bank)
  if type(bank) ~= "table" then
    fail({})
  end
  if bank.schema ~= AudioBank.SCHEMA then
    fail({ field = "schema" })
  end
  if not Validate.isNonNegativeInteger(bank.id) then
    fail({ field = "id" })
  end
  if bank.symbol ~= nil and (type(bank.symbol) ~= "string" or bank.symbol == "") then
    fail({ field = "symbol" })
  end
  -- The instruments-map grammar is the walk's; the visit enforces the strict
  -- leaf grammar (validateVoice raises its own structured errors), so a walk
  -- failure is the malformed-instruments problem.
  local ok = walkVoices(bank.instruments, function(_, voice)
    validateVoice(voice)
    return true
  end)
  if not ok then
    fail({ field = "instruments" })
  end
  return true
end

return AudioBank
