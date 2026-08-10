-- JointAnimBlend: Nitro-compatible combination of joint animation results.
-- This is a bit-exact transcription of pokediamond arm9/asm/NNS_G3D_anm.s
-- NNSi_G3dAnmBlendJnt (0x020B86B0), which blends the NNSG3dAnmResult of every
-- attachment with a positive ratio:
--
--   * attachments with non-positive ratio are ignored entirely;
--   * a single contributing attachment is returned as-is (asm shortcut);
--   * weights normalize over the summed ratios; a total of exactly 0x1000
--     keeps each ratio as its weight (FX_Div skipped);
--   * scale and inverse-scale vectors blend with 32-bit mul + asr #12, or
--     accumulate the weight directly when the channel is "from model";
--   * translation blends with the 64-bit FX_Mul (smull) semantics -- the
--     middle 32 bits of the full product -- NOT the 32-bit path;
--   * rotation cells 0-5 blend with 32-bit mul + asr #12; "from model" cells
--     accumulate the weight on cells 0 and 2 only, exactly like the asm;
--   * the flags word is the bitwise AND of the contributors.
--
-- After the loop the asm rebuilds the third row: row2 = cross(row0, row1),
-- row0 and row2 are normalized, then row1 = cross(row2, row0). VEC_CrossProduct
-- and VEC_Normalize are linked from the precompiled libsys, which the
-- pokediamond decomp does not contain; as with the NSBCA reconstruction, a
-- double-precision cross/normalize is used, which is within the established
-- bind-pose equivalence tolerance (32-bit products are exact in doubles; the
-- shift is the only truncation).
--
-- Do not substitute quaternion SLERP: the Nitro basis-vector blend above is
-- the engine's rotation combination contract for joint clips.
--
-- A result (NNSG3dAnmResult) is:
--   { flags, scale = {x,y,z}, scaleEx = {x,y,z}, rot = {9 cells},
--     trans = {x,y,z} } with every value an fx32 integer and
--   flags: bit 0 scale, bit 1 rot, bit 2 trans, bit 3 inverse scale
--     "from model" (the channel is resolved against the model bind pose
--     after the blend). Pure domain module.

local JointAnimBlend = {}

JointAnimBlend.FROM_MODEL = { scale = 0x01, rot = 0x02, trans = 0x04, inverseScale = 0x08 }

-- 32-bit signed wrap (two's complement).
local function wrap32(v)
  local p = v % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

-- The ARM `mul` path: the low 32 bits of the product, then an arithmetic
-- shift -- the two differ from the 64-bit path when the product overflows.
local function mul32(a, b)
  return wrap32(a * b)
end

-- The ARM `smull` path (FX_Mul): the middle 32 bits of the full 64-bit
-- product, i.e. (a * b) >> 12 as a signed 32-bit value. Doubles hold the
-- product exactly (32-bit factors fit in 53 bits).
local function fxMul64(a, b)
  return wrap32(math.floor(a * b / 4096))
end

-- Bitwise AND over the 5 flag bits.
local function bitAnd(a, b)
  local out = 0
  local bit = 1
  while bit <= 0x10 do
    if math.floor(a / bit) % 2 == 1 and math.floor(b / bit) % 2 == 1 then
      out = out + bit
    end
    bit = bit * 2
  end
  return out
end

-- A fresh zero result with everything "from model" (the asm's 0xFFFFFFFF
-- sentinel collapses to the 5 flag bits that ever participate).
local function newResult()
  return {
    flags = 0x1F,
    scale = { 0, 0, 0 },
    scaleEx = { 0, 0, 0 },
    rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    trans = { 0, 0, 0 },
  }
end

local function copyResult(r)
  return {
    flags = r.flags,
    scale = { r.scale[1], r.scale[2], r.scale[3] },
    scaleEx = { r.scaleEx[1], r.scaleEx[2], r.scaleEx[3] },
    rot = { r.rot[1], r.rot[2], r.rot[3], r.rot[4], r.rot[5], r.rot[6], r.rot[7], r.rot[8], r.rot[9] },
    trans = { r.trans[1], r.trans[2], r.trans[3] },
  }
end

-- blendScaleVec_ (0x020B8998): when the source channel is "from model" the
-- destination accumulates the weight directly; otherwise weight * src with
-- the 32-bit mul path.
local function blendScaleVec(dst, src, weight, fromModel)
  for i = 1, 3 do
    if fromModel then
      dst[i] = wrap32(dst[i] + weight)
    else
      dst[i] = wrap32(dst[i] + asr(mul32(weight, src[i]), 12))
    end
  end
end

-- Double-precision row normalization (VEC_Normalize stand-in, see header).
local function normalizeRow(cells, offset)
  local x, y, z = cells[offset + 1], cells[offset + 2], cells[offset + 3]
  local length = math.sqrt(x * x + y * y + z * z)
  if length == 0 then
    return
  end
  cells[offset + 1] = math.floor(x * 4096 / length)
  cells[offset + 2] = math.floor(y * 4096 / length)
  cells[offset + 3] = math.floor(z * 4096 / length)
end

-- Double-precision cross product (VEC_CrossProduct stand-in, see header):
-- out = cross(a, b), every product exact, one >> 12 per component.
local function cross(a, b)
  return {
    math.floor((a[2] * b[3] - a[3] * b[2]) / 4096),
    math.floor((a[3] * b[1] - a[1] * b[3]) / 4096),
    math.floor((a[1] * b[2] - a[2] * b[1]) / 4096),
  }
end

-- Rebuild the rotation's third row the way the asm does after blending:
-- row2 = cross(row0, row1); normalize row0 and row2; row1 = cross(row2, row0).
local function orthonormalize(rot)
  local row2 = cross({ rot[1], rot[2], rot[3] }, { rot[4], rot[5], rot[6] })
  rot[7], rot[8], rot[9] = row2[1], row2[2], row2[3]
  normalizeRow(rot, 0)
  normalizeRow(rot, 6)
  local row1 = cross({ rot[7], rot[8], rot[9] }, { rot[1], rot[2], rot[3] })
  rot[4], rot[5], rot[6] = row1[1], row1[2], row1[3]
end

-- A blended joint result (the NNSG3dAnmResult shape): every value an fx32
-- integer, with the "from model" flag bits (scale 0x1, rot 0x2, trans 0x4,
-- inverse scale 0x8).
---@class JointAnimResult
---@field flags integer
---@field scale integer[]
---@field scaleEx integer[]
---@field rot integer[]
---@field trans integer[]

-- Blend `entries` = { { ratio = fx32, result = result }, ... } into one
-- result. Returns nil when no attachment contributes (every ratio
-- non-positive), a copy when exactly one contributes, and the blended result
-- otherwise. Input results are never mutated.
---@return JointAnimResult|nil
function JointAnimBlend.blend(entries)
  assert(type(entries) == "table", "JointAnimBlend.blend requires a table")

  local contributing = {}
  for _, entry in ipairs(entries) do
    assert(
      type(entry) == "table" and entry.ratio ~= nil and entry.result ~= nil,
      "blend entries must carry a ratio and a result"
    )
    if entry.ratio > 0 then
      contributing[#contributing + 1] = entry
    end
  end
  if #contributing == 0 then
    return nil
  end
  if #contributing == 1 then
    return copyResult(contributing[1].result)
  end

  local total = 0
  for _, entry in ipairs(contributing) do
    total = total + entry.ratio
  end
  assert(total ~= 0, "contributing ratios sum to zero")

  local out = newResult()
  for _, entry in ipairs(contributing) do
    -- FX_Div is skipped when the total is exactly 0x1000 (asm compare).
    local weight
    if total == 0x1000 then
      weight = entry.ratio
    else
      weight = math.floor(entry.ratio * 4096 / total)
    end
    local r = entry.result

    blendScaleVec(out.scale, r.scale, weight, math.floor(r.flags / JointAnimBlend.FROM_MODEL.scale) % 2 == 1)
    blendScaleVec(out.scaleEx, r.scaleEx, weight, math.floor(r.flags / JointAnimBlend.FROM_MODEL.inverseScale) % 2 == 1)

    if math.floor(r.flags / JointAnimBlend.FROM_MODEL.trans) % 2 == 0 then
      for i = 1, 3 do
        out.trans[i] = wrap32(out.trans[i] + fxMul64(weight, r.trans[i]))
      end
    end

    if math.floor(r.flags / JointAnimBlend.FROM_MODEL.rot) % 2 == 1 then
      -- "From model" rotation: the weight lands on cells 0 and 2 only.
      out.rot[1] = wrap32(out.rot[1] + weight)
      out.rot[3] = wrap32(out.rot[3] + weight)
    else
      for i = 1, 6 do
        out.rot[i] = wrap32(out.rot[i] + asr(mul32(weight, r.rot[i]), 12))
      end
    end

    out.flags = bitAnd(out.flags, r.flags)
  end

  orthonormalize(out.rot)
  return out
end

return JointAnimBlend
