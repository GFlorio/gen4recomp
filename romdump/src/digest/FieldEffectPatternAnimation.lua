-- FieldEffectPatternAnimation: decodes the compact texture-pattern resources
-- used by HGSS field effects. The field-effect manager loads these resources
-- directly from field_static_models; they are not BTP0 files. Their layout is
-- documented by the texture-pattern accessors in pret/pokeheartgold's
-- lib/asm/nnsys.s and the renderer registrations in overlay_01_021F1348.s.
-- ROM-source parser; the normalized clip remains an asset-level contract.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local FieldEffectPatternAnimation = {}
FieldEffectPatternAnimation.FORMAT = "FIELD_EFFECT_PATTERN"

local function decode(bytes, context)
  assert(type(bytes) == "string", "FieldEffectPatternAnimation.decode requires bytes")
  local reader = BinaryReader.new(bytes, "field-effect-pattern")
  reader:assertRange(0, 4, "field-effect-pattern-count")
  local keyCount = reader:u32le(0)
  if keyCount < 1 then
    Errors.raise("FIELD_EFFECT_ANIMATION_INVALID", "field-effect pattern has no keys", context)
  end
  local frameTable = 4
  local valueTable = frameTable + keyCount * 2
  reader:assertRange(frameTable, keyCount * 2, "field-effect-pattern-frames")
  reader:assertRange(valueTable, keyCount, "field-effect-pattern-values")

  local keys = {}
  local previousFrame = -1
  for index = 0, keyCount - 1 do
    local frame = reader:u16le(frameTable + index * 2)
    if frame <= previousFrame then
      Errors.raise("FIELD_EFFECT_ANIMATION_INVALID", "field-effect pattern frames are not strictly increasing", {
        index = index,
        frame = frame,
        previousFrame = previousFrame,
      })
    end
    previousFrame = frame
    keys[#keys + 1] = { frame = frame, texIdx = reader:u8(valueTable + index), plttIdx = 0xFF }
  end
  return { frameCount = previousFrame + 1, keys = keys }
end

---@param bytes string
---@param context table|nil
---@return table|nil, table|nil
function FieldEffectPatternAnimation.decode(bytes, context)
  local ok, result = pcall(decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    if result.code == "READ_OUT_OF_BOUNDS" then
      return nil,
        Errors.new("FIELD_EFFECT_ANIMATION_INVALID", "field-effect pattern is truncated", {
          source = result.context,
        })
    end
    return nil, result
  end
  error(result)
end

return FieldEffectPatternAnimation
