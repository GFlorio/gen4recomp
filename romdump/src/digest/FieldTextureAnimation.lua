-- Decoder for the HGSS field texture-animation table: the member-0
-- contents of `data/fldtanime.narc` in pret/pokeheartgold (dump alias
-- `field_texture_animations`). The member is a little-endian u32 record count
-- followed by fixed 52-byte records of a NUL-padded 16-byte name and an
-- 18-pair schedule; each record's replacement texture resource is archive
-- member `recordIndex + 1`. A schedule ends at the first pair whose
-- textureIndex is 0xFF (the duration byte is irrelevant and pairs after the
-- terminator are ignored, matching the game's counter state machine), live
-- durations may be zero, the table needs at least the bytes its declared
-- records occupy, names must be non-empty and unique after the Nitro
-- fixed-string rules, and a record whose first pair is the terminator is
-- malformed. `textureIndex` is not validated against a BTX0 dictionary here;
-- that belongs to compilation. Pure domain module; parse() returns
-- (records | nil, err) and raises structured Errors only for malformed input.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local FieldTextureAnimation = {}

-- Structured error codes owned by this module.
FieldTextureAnimation.ERROR_SIZE = "FIELD_TEX_ANIM_SIZE_MISMATCH"
FieldTextureAnimation.ERROR_EMPTY_NAME = "FIELD_TEX_ANIM_EMPTY_NAME"
FieldTextureAnimation.ERROR_DUPLICATE_NAME = "FIELD_TEX_ANIM_DUPLICATE_NAME"
FieldTextureAnimation.ERROR_MISSING_TERMINATOR = "FIELD_TEX_ANIM_MISSING_TERMINATOR"
FieldTextureAnimation.ERROR_EMPTY_TIMELINE = "FIELD_TEX_ANIM_EMPTY_TIMELINE"

-- The schedule terminator: a textureIndex of 0xFF ends the live schedule,
-- whatever the paired duration byte holds.
FieldTextureAnimation.TERMINATOR = 0xFF

local COUNT_SIZE = 4
local RECORD_SIZE = 52
local NAME_SIZE = 16
local PAIR_COUNT = 18

local function fail(code, message, context, extra)
  extra = extra or {}
  extra.source = context
  Errors.raise(code, message, extra)
end

local function parse(bytes, context)
  if #bytes < COUNT_SIZE then
    fail(
      FieldTextureAnimation.ERROR_SIZE,
      "field texture-animation table is " .. #bytes .. " bytes, need at least " .. COUNT_SIZE,
      context,
      { size = #bytes, expected = COUNT_SIZE }
    )
  end
  local r = BinaryReader.new(bytes, "field-texture-animation-table")
  local recordCount = r:u32le(0)
  local requiredSize = COUNT_SIZE + recordCount * RECORD_SIZE
  if #bytes < requiredSize then
    fail(
      FieldTextureAnimation.ERROR_SIZE,
      "field texture-animation table is "
        .. #bytes
        .. " bytes, need "
        .. requiredSize
        .. " for "
        .. recordCount
        .. " records",
      context,
      { size = #bytes, recordCount = recordCount, expected = requiredSize }
    )
  end

  local records = {}
  local seenNames = {}
  for recordIndex = 0, recordCount - 1 do
    local offset = COUNT_SIZE + recordIndex * RECORD_SIZE
    local name = r:ascii(offset, NAME_SIZE, true)
    if name == "" then
      fail(
        FieldTextureAnimation.ERROR_EMPTY_NAME,
        "field texture-animation record " .. recordIndex .. " has an empty name",
        context,
        { recordIndex = recordIndex }
      )
    end
    if seenNames[name] then
      fail(
        FieldTextureAnimation.ERROR_DUPLICATE_NAME,
        "field texture-animation record " .. recordIndex .. " repeats name " .. name,
        context,
        { name = name, recordIndex = recordIndex }
      )
    end
    seenNames[name] = true

    local timeline = {}
    local pairBase = offset + NAME_SIZE
    local terminated = false
    for pairIndex = 0, PAIR_COUNT - 1 do
      local pair = pairBase + pairIndex * 2
      local textureIndex = r:u8(pair)
      local durationTicks = r:u8(pair + 1)
      if textureIndex == FieldTextureAnimation.TERMINATOR then
        terminated = true
        break
      end
      timeline[#timeline + 1] = {
        textureIndex = textureIndex,
        durationTicks = durationTicks,
      }
    end
    if not terminated then
      fail(
        FieldTextureAnimation.ERROR_MISSING_TERMINATOR,
        "field texture-animation record " .. recordIndex .. " has no terminator within its " .. PAIR_COUNT .. " pairs",
        context,
        { recordIndex = recordIndex }
      )
    end
    if #timeline == 0 then
      fail(
        FieldTextureAnimation.ERROR_EMPTY_TIMELINE,
        "field texture-animation record " .. recordIndex .. " terminates at its first pair",
        context,
        { recordIndex = recordIndex }
      )
    end

    records[#records + 1] = {
      index = recordIndex,
      name = name,
      timeline = timeline,
    }
  end
  return records
end

function FieldTextureAnimation.parse(bytes, context)
  assert(type(bytes) == "string", "FieldTextureAnimation.parse requires a string")
  local ok, result = pcall(parse, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldTextureAnimation
