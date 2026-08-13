-- Static texture-SRT extension of a Nitro material: the bytes after the
-- fixed NNSG3dResMatData prefix (+0x2C), governed by bits of the material's
-- flags word (+0x1E).
--
-- Authority: pokediamond arm9/asm/NNS_G3D_sbc.s, the SBC MAT handler
-- (NNSi_G3dFuncSbc_MAT_InternalDefault, ~0x020B8BC4), which locates the
-- material record, tests the flags, and skips the present components to
-- reach the texture matrix; layout cross-verified against all 29 real
-- HGSS field materials that carry the extension. Flags:
--
--   bit 1 (0x002): scale absent      bit 2 (0x004): rotation absent
--   bit 3 (0x008): translation absent
--   bit 13 (0x2000): the record is a precomputed 4x4 texture matrix
--                    (64 bytes); the SBC MAT loads it via MTX_MULT_4x4
--
-- With bit 13 clear the record holds the components in fixed order, each
-- present only when its absence bit is clear:
--
--   +0x00 scale: 2 x fx32 (S, T)
--   +0x08 rotation: u16 sin, u16 cos (fx16)
--   +0x0C translation: 2 x fx32 (S, T)
--
-- Sizes seen in the field corpus: 4 (no components), 8 (one), 16 (two) and
-- 64 (the matrix form). The static values initialize the material's texture
-- state the same way a BTA clip drives it at runtime. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local NsbmdMaterialSrt = {}

local FLAG_SCALE_ABSENT = 0x002
local FLAG_ROT_ABSENT = 0x004
local FLAG_TRANS_ABSENT = 0x008
local FLAG_MATRIX_FORM = 0x2000

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

-- Decode the texture-SRT extension. Returns nil when the material carries
-- none (all three components absent), otherwise:
--   { scale = { s, t }, rot = { sin, cos }, trans = { s, t },
--     matrix = 16-word 4x4 (matrix form only), flagRaw }
-- with the absent components nil.
function NsbmdMaterialSrt.decode(flagsRaw, extraBytes)
  assert(type(extraBytes) == "string", "NsbmdMaterialSrt.decode requires bytes")
  local r = BinaryReader.new(extraBytes, "material-srt")

  if bitSet(flagsRaw, FLAG_MATRIX_FORM) then
    r:assertRange(0, 64, "material-srt-matrix")
    local matrix = {}
    for i = 0, 15 do
      matrix[i + 1] = r:u32le(i * 4)
    end
    return { flagRaw = flagsRaw, matrix = matrix }
  end

  local srt = { flagRaw = flagsRaw }
  local at = 0
  if not bitSet(flagsRaw, FLAG_SCALE_ABSENT) then
    r:assertRange(at, 8, "material-srt-scale")
    srt.scale = { s = r:u32le(at), t = r:u32le(at + 4) }
    at = at + 8
  end
  if not bitSet(flagsRaw, FLAG_ROT_ABSENT) then
    r:assertRange(at, 4, "material-srt-rot")
    srt.rot = { sin = r:u16le(at), cos = r:u16le(at + 2) }
    at = at + 4
  end
  if not bitSet(flagsRaw, FLAG_TRANS_ABSENT) then
    r:assertRange(at, 8, "material-srt-trans")
    srt.trans = { s = r:u32le(at), t = r:u32le(at + 4) }
  end
  if srt.scale == nil and srt.rot == nil and srt.trans == nil then
    return nil
  end
  return srt
end

return NsbmdMaterialSrt
