-- Strict decoder for the HGSS field texture-animation table: the member-0
-- contents of `data/fldtanime.narc` in pret/pokeheartgold (dump alias
-- `field_texture_animations`). The member is a little-endian u32 record count
-- followed by fixed 52-byte records of a NUL-padded 16-byte name and an
-- 18-pair schedule; each record's replacement texture resource is archive
-- member `recordIndex + 1`. Parsing is strict: the member length must equal
-- 4 + recordCount * 52 exactly, names must be non-empty and unique after the
-- Nitro fixed-string rules, the schedule must contain a { 0xFF, 0xFF }
-- sentinel within its 18 pairs with sentinel-only pairs after it, and every
-- live duration must be positive. `textureIndex` is not validated against a
-- BTX0 dictionary here; that belongs to compilation. Pure domain module;
-- parse() returns (records | nil, err) and raises structured Errors only for
-- malformed input.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local FieldTextureAnimation = {}

local COUNT_SIZE = 4
local RECORD_SIZE = 52
local NAME_SIZE = 16
local PAIR_COUNT = 18
local SENTINEL_VALUE = 0xFF

local function fail(code, message, context, extra)
  extra = extra or {}
  extra.source = context
  Errors.raise(code, message, extra)
end

local function parse(bytes, context)
  if #bytes < COUNT_SIZE then
    fail(
      "FIELD_TEX_ANIM_SIZE_MISMATCH",
      "field texture-animation table is " .. #bytes .. " bytes, need at least " .. COUNT_SIZE,
      context,
      { size = #bytes, expected = COUNT_SIZE }
    )
  end
  local r = BinaryReader.new(bytes, "field-texture-animation-table")
  local recordCount = r:u32le(0)
  local expected = COUNT_SIZE + recordCount * RECORD_SIZE
  if #bytes ~= expected then
    fail(
      "FIELD_TEX_ANIM_SIZE_MISMATCH",
      "field texture-animation table is "
        .. #bytes
        .. " bytes, expected "
        .. expected
        .. " for "
        .. recordCount
        .. " records",
      context,
      { size = #bytes, recordCount = recordCount, expected = expected }
    )
  end

  local records = {}
  local seenNames = {}
  for recordIndex = 0, recordCount - 1 do
    local offset = COUNT_SIZE + recordIndex * RECORD_SIZE
    local name = r:ascii(offset, NAME_SIZE, true)
    if name == "" then
      fail(
        "FIELD_TEX_ANIM_EMPTY_NAME",
        "field texture-animation record " .. recordIndex .. " has an empty name",
        context,
        { recordIndex = recordIndex }
      )
    end
    if seenNames[name] then
      fail(
        "FIELD_TEX_ANIM_DUPLICATE_NAME",
        "field texture-animation record " .. recordIndex .. " repeats name " .. name,
        context,
        { name = name, recordIndex = recordIndex }
      )
    end
    seenNames[name] = true

    local timeline = {}
    local sentinelSeen = false
    local pairBase = offset + NAME_SIZE
    for pairIndex = 0, PAIR_COUNT - 1 do
      local pair = pairBase + pairIndex * 2
      local textureIndex = r:u8(pair)
      local durationTicks = r:u8(pair + 1)
      local isSentinel = textureIndex == SENTINEL_VALUE and durationTicks == SENTINEL_VALUE
      local isHalfSentinel = textureIndex == SENTINEL_VALUE or durationTicks == SENTINEL_VALUE
      if sentinelSeen then
        if not isSentinel then
          fail(
            "FIELD_TEX_ANIM_BAD_SENTINEL",
            "field texture-animation record " .. recordIndex .. " hides data after its sentinel at pair " .. pairIndex,
            context,
            { recordIndex = recordIndex, pairIndex = pairIndex }
          )
        end
      elseif isHalfSentinel then
        if not isSentinel then
          fail(
            "FIELD_TEX_ANIM_BAD_SENTINEL",
            "field texture-animation record " .. recordIndex .. " has a half sentinel at pair " .. pairIndex,
            context,
            { recordIndex = recordIndex, pairIndex = pairIndex }
          )
        end
        sentinelSeen = true
      else
        if durationTicks == 0 then
          fail(
            "FIELD_TEX_ANIM_ZERO_DURATION",
            "field texture-animation record " .. recordIndex .. " has a zero duration at pair " .. pairIndex,
            context,
            { recordIndex = recordIndex, pairIndex = pairIndex }
          )
        end
        timeline[#timeline + 1] = {
          textureIndex = textureIndex,
          durationTicks = durationTicks,
        }
      end
    end
    if not sentinelSeen then
      fail(
        "FIELD_TEX_ANIM_MISSING_SENTINEL",
        "field texture-animation record " .. recordIndex .. " has no sentinel within its " .. PAIR_COUNT .. " pairs",
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
