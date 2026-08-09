-- JointAnimBlend: Nitro-compatible combination of joint results, a bit-exact
-- transcription of NNSi_G3dAnmBlendJnt (pokediamond arm9/asm/NNS_G3D_anm.s
-- 0x020B86B0).

local Assert = require("tests.support.Assert")
local JointAnimBlend = require("libs.engine.src.JointAnimBlend")

local T = {}

local F = JointAnimBlend.FROM_MODEL

local function result(overrides)
  local r = {
    flags = 0,
    scale = { 0x1000, 0x1000, 0x1000 },
    scaleEx = { 0x1000, 0x1000, 0x1000 },
    rot = { 0x1000, 0, 0, 0, 0x1000, 0, 0, 0, 0x1000 },
    trans = { 0, 0, 0 },
  }
  for k, v in pairs(overrides or {}) do r[k] = v end
  return r
end

local function deepCopy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = type(v) == "table" and deepCopy(v) or v
  end
  return out
end

-- The engine's fxMul64: (a * b) >> 12 with 32-bit signed wrap.
local function fxMul64(a, b)
  local p = math.floor(a * b / 4096) % 4294967296
  if p >= 2147483648 then p = p - 4294967296 end
  return p
end

-- The ARM 32-bit mul path, derived from two's complement arithmetic: take the
-- low 32 bits of the product as signed, then shift arithmetically.
local function mul32Path(a, b)
  local low = a * b % 4294967296
  if low >= 2147483648 then low = low - 4294967296 end
  return math.floor(low / 4096)
end

local function assertDeepEqual(actual, expected, path)
  if type(expected) == "number" then
    Assert.equal(actual, expected, path .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
  else
    for k, v in pairs(expected) do
      assertDeepEqual(actual[k], v, path .. "." .. tostring(k))
    end
  end
end

function T.no_positive_ratio_returns_nil()
  local r = result()
  Assert.isNil(JointAnimBlend.blend({ { ratio = 0, result = r }, { ratio = -1, result = r } }))
  Assert.isNil(JointAnimBlend.blend({}))
end

function T.single_contribution_is_copied()
  local r = result({ trans = { 0x1234, 0, 0 }, flags = F.scale })
  local out = JointAnimBlend.blend({ { ratio = 0x1000, result = r } })
  assertDeepEqual(out, r, "out")
  Assert.isFalse(out == r, "the result is a copy, not the input")
  r.trans[1] = 9999
  Assert.equal(out.trans[1], 0x1234, "mutating the input does not touch the output")
end

function T.equal_ratios_average_channels()
  local a = result({ trans = { 0x1000, 0, 0 }, scale = { 0x1000, 0x1000, 0x1000 } })
  local b = result({ trans = { 0x3000, 0, 0 }, scale = { 0x3000, 0x1000, 0x1000 } })
  -- total == 0x1000: weights are the ratios themselves (0x800 each).
  local out = JointAnimBlend.blend({ { ratio = 0x800, result = a }, { ratio = 0x800, result = b } })
  Assert.equal(out.trans[1], 0x2000)
  Assert.equal(out.trans[2], 0)
  Assert.equal(out.scale[1], 0x2000)
  Assert.equal(out.scale[2], 0x1000)
  Assert.equal(out.flags, 0, "flags AND with no from-model bits")
end

function T.unequal_ratios_normalize_with_fx_div()
  local a = result({ trans = { 0x1000, 0, 0 } })
  local b = result({ trans = { 0x3000, 0, 0 } })
  -- total 0xC00: weights floor(0x800 * 0x1000 / 0xC00) = 0xAAA and
  -- floor(0x400 * 0x1000 / 0xC00) = 0x555.
  local weightA = math.floor(0x800 * 0x1000 / 0xC00)
  local weightB = math.floor(0x400 * 0x1000 / 0xC00)
  local out = JointAnimBlend.blend({ { ratio = 0x800, result = a }, { ratio = 0x400, result = b } })
  Assert.equal(out.trans[1], fxMul64(weightA, 0x1000) + fxMul64(weightB, 0x3000))
end

function T.translation_uses_64bit_fx_mul()
  -- The 32-bit and 64-bit paths diverge on values near int32 overflow.
  local a = result({ trans = { 0x7FFFFFFF, 0, 0 }, scale = { 0x7FFFFFFF, 0x1000, 0x1000 } })
  local b = result()
  local out = JointAnimBlend.blend({ { ratio = 0x1000, result = a }, { ratio = 0x1000, result = b } })
  -- total 0x2000, weights 0x800 each.
  Assert.equal(out.trans[1], fxMul64(0x800, 0x7FFFFFFF), "64-bit FX_Mul keeps the middle bits")
  Assert.equal(out.scale[1], mul32Path(0x800, 0x7FFFFFFF) + 0x800,
    "32-bit path takes the low bits, then shifts")
end

function T.from_model_scale_accumulates_weight()
  local a = result({ flags = F.scale, scale = { 1, 2, 3 } })
  local b = result()
  local out = JointAnimBlend.blend({ { ratio = 0x800, result = a }, { ratio = 0x800, result = b } })
  -- a: dst += weight (0x800) per component; b: 0x800 * 0x1000 >> 12 = 0x800.
  Assert.equal(out.scale[1], 0x1000)
  Assert.equal(out.scale[2], 0x800 + 0x800)
  Assert.equal(out.scale[3], 0x800 + 0x800)
end

function T.from_model_rotation_accumulates_weight_on_two_cells()
  -- A "from model" rotation accumulates the weight on cells 0 and 2 only
  -- (asm cell indices 0 and 2), then the rows are re-normalized like every
  -- blended rotation. Without the accumulation, row 0 of b would be
  -- (0, 0, +1); with it the row gains an X component of 0x1000.
  local a = result({ flags = F.rot, rot = { 0, 0, 0, 0, 0, 0, 0, 0, 0 } })
  local b = result({ rot = { 0, 0, 0x1000, 0, 0x1000, 0, -0x1000, 0, 0 } })
  local out = JointAnimBlend.blend({ { ratio = 0x1000, result = a }, { ratio = 0x1000, result = b } })
  -- Row 0 = (0x1000 + 0, 0, 0x1000 + 0x1000) = (0x1000, 0, 0x2000), normalized
  -- component-wise with floor (the documented VEC_Normalize stand-in).
  local expectedX = math.floor(0x1000 * 4096 / (math.sqrt(5) * 0x1000))
  local expectedZ = math.floor(0x2000 * 4096 / (math.sqrt(5) * 0x1000))
  Assert.equal(out.rot[1], expectedX, "weight accumulated on cell 0 only")
  Assert.equal(out.rot[3], expectedZ, "cell 2 keeps b's blend plus the weight")
  Assert.equal(out.flags, 0, "flags AND with b's zero")
  -- The single-contribution control has no X component at all.
  local control = JointAnimBlend.blend({ { ratio = 0x1000, result = b } })
  Assert.equal(control.rot[1], 0)
end

function T.flags_are_and_combined()
  local a = result({ flags = F.scale + F.trans })
  local b = result({ flags = F.scale + F.rot })
  local out = JointAnimBlend.blend({ { ratio = 0x800, result = a }, { ratio = 0x800, result = b } })
  Assert.equal(out.flags, F.scale)
  Assert.equal(JointAnimBlend.blend({ { ratio = 1, result = result({ flags = 0 }) } }).flags, 0)
end

function T.blended_rotation_is_orthonormalized()
  -- Identity + 90-degree rotY, blended 50/50, then rebuilt like the asm:
  -- row2 = cross(row0, row1), rows 0 and 2 normalize, row1 = cross(row2, row0).
  local identity = result()
  local rotY90 = result({ rot = { 0, 0, -0x1000, 0, 0x1000, 0, 0x1000, 0, 0 } })
  local out = JointAnimBlend.blend({
    { ratio = 0x800, result = identity }, { ratio = 0x800, result = rotY90 },
  })

  local row0 = { out.rot[1], out.rot[2], out.rot[3] }
  local row1 = { out.rot[4], out.rot[5], out.rot[6] }
  local row2 = { out.rot[7], out.rot[8], out.rot[9] }
  local function length(v)
    return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
  end
  -- Rows are unit length (within one fx32 unit of 0x1000) and pairwise
  -- orthogonal within the floor-truncation skew of the double-precision
  -- normalize stand-in (a component error of one unit at 4096 scale).
  for _, v in ipairs({ row0, row1, row2 }) do
    Assert.near(length(v), 0x1000, 1.5, "row is unit length")
  end
  Assert.near(row0[1] * row1[1] + row0[2] * row1[2] + row0[3] * row1[3], 0, 0x1000)
  Assert.near(row0[1] * row2[1] + row0[2] * row2[2] + row0[3] * row2[3], 0, 0x1000)
  Assert.near(row1[1] * row2[1] + row1[2] * row2[2] + row1[3] * row2[3], 0, 0x1000)
  -- Row 0 is the normalized blend of (0x1000,0,0) and (0,0,-0x1000):
  -- (0x800, 0, -0x800); the floor of the negative component lands one unit
  -- low (-2897, not -2896). Row 1 is rebuilt as the cross of rows 2 and 0.
  Assert.equal(out.rot[1], math.floor(0x800 * 4096 / math.sqrt(2 * 0x800 * 0x800)))
  Assert.equal(out.rot[3], -2897)
  Assert.equal(out.rot[5], 4095)
end

function T.blend_never_mutates_inputs()
  local a = result({ trans = { 0x1000, 0, 0 }, flags = F.scale })
  local b = result({ trans = { 0x3000, 0, 0 }, flags = F.rot })
  local beforeA, beforeB = deepCopy(a), deepCopy(b)
  JointAnimBlend.blend({ { ratio = 0x800, result = a }, { ratio = 0x400, result = b } })
  assertDeepEqual(a, beforeA, "a")
  assertDeepEqual(b, beforeB, "b")
end

return T
