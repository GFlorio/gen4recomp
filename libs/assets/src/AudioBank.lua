-- Validator for the derived audio bank asset: numeric and symbolic identity,
-- its wave-archive slot map, and a program-keyed instruments map. Instrument
-- kinds are the semantic direct/key_split/drum_set (never SBNK record
-- types), and every leaf voice has the common shape {generator, originalKey,
-- envelope, pan}: sample voices add the content-address key, and
-- square/noise voices carry their source original key like every other leaf.
-- `sampleKeys` is the shared reference walk: it collects the content-address
-- keys every voice of a bank references, returning nil when the instrument
-- shape is malformed, so a malformed shape can never be mistaken for "no
-- sample references" (AudioCache readiness relies on it).

local AudioBank = {}

local Validate = require("libs.assets.src.Validate")
local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

AudioBank.SCHEMA = Contract.audio.bankSchema

local function fail(context)
  Errors.raise("AUDIO_BANK_INVALID", "malformed audio bank asset", context)
end

local function isIntegerInRange(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

local function isKey(value)
  return isIntegerInRange(value, 0, 0x7F)
end

-- Walks every leaf voice of an instruments map. `visit(voice)` decides
-- acceptance; returning false aborts the walk with a falsy result, so a
-- malformed shape is a failed walk, never an empty reference set.
---@param instruments table
---@param visit fun(voice: table): boolean
---@return boolean
local function walkVoices(instruments, visit)
  if type(instruments) ~= "table" or next(instruments) == nil then
    return false
  end
  for _, instrument in pairs(instruments) do
    if type(instrument) ~= "table" then
      return false
    end
    if instrument.kind == "direct" then
      if type(instrument.voice) ~= "table" or not visit(instrument.voice) then
        return false
      end
    elseif instrument.kind == "key_split" then
      if not Validate.isArray(instrument.ranges) or #instrument.ranges == 0 then
        return false
      end
      for _, range in ipairs(instrument.ranges) do
        if type(range) ~= "table" or type(range.voice) ~= "table" or not visit(range.voice) then
          return false
        end
      end
    elseif instrument.kind == "drum_set" then
      if not Validate.isArray(instrument.voices) or #instrument.voices == 0 then
        return false
      end
      for _, voice in ipairs(instrument.voices) do
        if type(voice) ~= "table" or not visit(voice) then
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
-- instrument shape is malformed. The same walk backs AudioBank.validate and
-- AudioCache readiness, so reference resolution and validation can never
-- drift apart.
---@param bank table
---@return string[]|nil
function AudioBank.sampleKeys(bank)
  if type(bank) ~= "table" then
    return nil
  end
  local keys, seen = {}, {}
  local ok = walkVoices(bank.instruments, function(voice)
    if type(voice.generator) ~= "table" then
      return false
    end
    local generator = voice.generator
    if generator.kind == "sample" then
      if type(generator.sample) ~= "string" then
        return false
      end
      if not seen[generator.sample] then
        seen[generator.sample] = true
        keys[#keys + 1] = generator.sample
      end
    end
    return true
  end)
  if not ok then
    return nil
  end
  return keys
end

local function validateVoice(voice)
  if type(voice) ~= "table" then
    fail({ field = "voice" })
  end
  local generator = voice.generator
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
    if type(generator.duty) ~= "number" or generator.duty < 0 or generator.duty > 1 then
      fail({ field = "voice.generator.duty" })
    end
  elseif generator.kind == "noise" then
    -- bare generator: no parameters
  else
    fail({ field = "voice.generator.kind" })
  end
  local envelope = voice.envelope
  if type(envelope) ~= "table" then
    fail({ field = "voice.envelope" })
  end
  for _, field in ipairs({ "attack", "decay", "sustain", "release" }) do
    if not isIntegerInRange(envelope[field], 0, 0x7F) then
      fail({ field = "voice.envelope." .. field })
    end
  end
  if not isIntegerInRange(voice.pan, 0, 0x7F) then
    fail({ field = "voice.pan" })
  end
end

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
  if bank.waveArchives ~= nil then
    if type(bank.waveArchives) ~= "table" then
      fail({ field = "waveArchives" })
    end
    for slot, waveId in pairs(bank.waveArchives) do
      if not isIntegerInRange(slot, 0, 3) then
        fail({ field = "waveArchives.slot" })
      end
      if not isIntegerInRange(waveId, 0, 0xFFFF) then
        fail({ field = "waveArchives.waveId" })
      end
    end
  end
  if type(bank.instruments) ~= "table" or next(bank.instruments) == nil then
    fail({ field = "instruments" })
  end
  for key, instrument in pairs(bank.instruments) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 then
      fail({ field = "instruments.key" })
    end
    if type(instrument) ~= "table" then
      fail({ field = "instruments[" .. tostring(key) .. "]" })
    end
    if instrument.kind == "direct" then
      validateVoice(instrument.voice)
    elseif instrument.kind == "key_split" then
      if not Validate.isArray(instrument.ranges) or #instrument.ranges == 0 then
        fail({ field = "instruments[" .. tostring(key) .. "].ranges" })
      end
      for _, range in ipairs(instrument.ranges) do
        if type(range) ~= "table" or not isKey(range.lowKey) or not isKey(range.highKey) then
          fail({ field = "instruments[" .. tostring(key) .. "].ranges" })
        end
        if range.lowKey > range.highKey then
          fail({ field = "instruments[" .. tostring(key) .. "].ranges" })
        end
        validateVoice(range.voice)
      end
    elseif instrument.kind == "drum_set" then
      if not isKey(instrument.lowKey) or not isKey(instrument.highKey) or instrument.lowKey > instrument.highKey then
        fail({ field = "instruments[" .. tostring(key) .. "]" })
      end
      if not Validate.isArray(instrument.voices) then
        fail({ field = "instruments[" .. tostring(key) .. "].voices" })
      end
      if #instrument.voices ~= instrument.highKey - instrument.lowKey + 1 then
        fail({ field = "instruments[" .. tostring(key) .. "].voices" })
      end
      for _, voice in ipairs(instrument.voices) do
        validateVoice(voice)
      end
    else
      fail({ field = "instruments[" .. tostring(key) .. "].kind" })
    end
  end
  return true
end

return AudioBank
