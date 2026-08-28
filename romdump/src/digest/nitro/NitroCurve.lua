-- NSBCA-style sampled curve: a (u32 flag, u32 ofs) channel record plus its
-- fx16/fx32 key array, sampled exactly as NitroSystem samples it.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbca.s (pinned commit
-- 038cccaed, 2025-12-24) -- getTransData_/getTransDataEx_/getScaleData_/
-- getScaleDataEx_/getRotDataEx_ all share this machinery. Channel flag:
--
--   bits 16-28 (0x1FFF0000): limit -- the key count at full rate, always
--          numFrame (verified for all 85 NSBCA members of the HGSS field
--          archive; the clip compilers assert limit == numFrame, and the
--          callers clamp frames to numFrame - 1, so the sampler never
--          sees a frame past the last key)
--   bit 29   (0x20000000): fx16 storage (u16 keys; else fx32 u32 keys).
--          Rotation channels ignore this bit and always use u16 keys.
--   bit 30   (0x40000000): half rate (2 frames per key, stored values
--          pre-scaled x2, results shifted >>1)
--   bit 31   (0x80000000): quarter rate (4 frames per key, x4, >>2)
--
-- The samplers reproduce the asm bit-for-bit, including the curve path's
-- 32-bit multiply truncation (the blend path uses the 64-bit FX_Mul -- this
-- one does not) and the non-Ex integer path's odd-frame averages.
-- Pure domain module.

local NitroCurve = {}

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

NitroCurve.FULL = 1
NitroCurve.HALF = 2
NitroCurve.QUARTER = 4

local BIT_HALF = 0x40000000
local BIT_FX16 = 0x20000000

-- The low 32 bits of a signed product, as the asm `mul` leaves it.
---@param a number
---@param b number
---@return number
local function mul32(a, b)
  local p = (a * b) % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

-- Arithmetic shift right, as `asr` shifts: floor division by 2^bits.
local function asr(value, bits)
  return math.floor(value / 2 ^ bits)
end

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

-- Decode one (flag, ofs) channel record at `at` (absolute within `r`).
-- Nothing from the key array is read until sample(). `keysPerValue` is 1 for
-- scalar channels (translation, rotation) and 2 for scale pairs
-- (scale, inverseScale).
function NitroCurve.decode(r, at, keysPerValue, context)
  r:assertRange(at, 8, "anm-curve")
  local flag = r:u32le(at)
  local ofs = r:u32le(at + 4)

  local rate = NitroCurve.FULL
  if bitSet(flag, BIT_HALF) then
    rate = NitroCurve.HALF
  elseif bitSet(flag, 0x80000000) then
    rate = NitroCurve.QUARTER
  end

  local curve = {
    flagRaw = flag,
    ofs = ofs,
    storage = bitSet(flag, BIT_FX16) and "fx16" or "fx32",
    rate = rate,
    limit = math.floor(flag / 65536) % 8192,
    keysPerValue = keysPerValue or 1,
    keyBase = ofs,
    source = context,
  }
  setmetatable(curve, { __index = NitroCurve })
  return curve
end

-- Byte offset of key `keyIndex` within the section.
function NitroCurve:keyOffset(keyIndex)
  if self.storage == "fx16" then
    return self.keyBase + keyIndex * 2 * self.keysPerValue
  end
  return self.keyBase + keyIndex * 4 * self.keysPerValue
end

-- Read one key. Returns a table of 1 or 2 values (scale pairs: scale first,
-- inverse scale second) as the raw storage words the asm uses: fx16 keys are
-- sign-extended 16-bit words, fx32 keys are the raw 32-bit words.
function NitroCurve:readKey(r, keyIndex)
  local at = self:keyOffset(keyIndex)
  if self.storage == "fx16" then
    r:assertRange(at, 2 * self.keysPerValue, "anm-curve-key")
    if self.keysPerValue == 2 then
      return { s16(r:u16le(at)), s16(r:u16le(at + 2)) }
    end
    return { s16(r:u16le(at)) }
  end
  r:assertRange(at, 4 * self.keysPerValue, "anm-curve-key")
  if self.keysPerValue == 2 then
    return { r:u32le(at), r:u32le(at + 4) }
  end
  return { r:u32le(at) }
end

-- Ex-path interpolation: (a*step + mul32(b - a, frac) >> 12) >> log2(step).
local function lerpEx(a, b, step, frac)
  local delta = mul32(b - a, frac)
  return asr(a * step + asr(delta, 12), step == NitroCurve.HALF and 1 or step == NitroCurve.QUARTER and 2 or 0)
end

-- Sample both key values at `frameFx` (a fixed-point frame that must already
-- be clamped to [0, numFrame << 12 - 1]). Returns { a, b } where b is nil
-- for scalar channels (translation, rotation) and the inverse scale for
-- scale pairs. `numFrame` selects the final-frame path; `interpolate`
-- enables the fractional-frame Ex path (resource flag bit 0); `wrapFinal`
-- enables the final-frame wrap toward key[0] (resource flag bit 1).
function NitroCurve:sampleValues(r, frameFx, numFrame, interpolate, wrapFinal)
  local frame = math.floor(frameFx / 4096)
  local frac = frameFx % 4096
  local step = self.rate
  local index = math.floor(frame / self.rate)

  local function at(keyIndex)
    return self:readKey(r, keyIndex)
  end
  -- Apply `fn` per present component to the keys at indices i and j.
  local function between(i, j, fn)
    local a = at(i)
    local b = at(j)
    local out = { fn(a[1], b[1]) }
    if a[2] ~= nil then
      out[2] = fn(a[2], b[2])
    end
    return out
  end

  -- Final frame with the wrap flag: interpolate key[last] toward key[0].
  if wrapFinal and frame == numFrame - 1 and frac ~= 0 then
    return between(index, 0, function(v1, v2)
      return v1 + asr(mul32(v2 - v1, frac), 12)
    end)
  end

  if interpolate and frac ~= 0 then
    -- Ex path: keys at index and index+1, 12/13/14-bit fractional part.
    -- limit == numFrame and the frame is clamped to numFrame - 1, so the
    -- frame never passes the last key (no tail branch).
    local fracWide = frameFx % (4096 * step)
    return between(index, index + 1, function(a, b)
      return lerpEx(a, b, step, fracWide)
    end)
  end

  -- Integer path.
  if step == NitroCurve.HALF then
    if frame % 2 == 1 then
      if self.storage == "fx32" then
        return between(index, index + 1, function(a, b)
          return asr(a, 1) + asr(b, 1)
        end)
      end
      return between(index, index + 1, function(a, b)
        return asr(a + b, 1)
      end)
    end
    return at(index)
  elseif step == NitroCurve.QUARTER then
    if frame % 4 ~= 0 then
      if frame % 4 == 2 then
        return between(index, index + 1, function(a, b)
          return asr(a + b, 1)
        end)
      end
      -- 3:1 toward the nearer key: the later key for frame % 4 == 3.
      local a, b = index, index + 1
      if frame % 4 == 3 then
        a, b = b, a
      end
      return between(a, b, function(x, y)
        return asr(3 * x + y, 2)
      end)
    end
    return at(index)
  end
  return at(frame)
end

-- Sample the scalar channel. Returns the sampled fx value.
function NitroCurve:sample(r, frameFx, numFrame, interpolate, wrapFinal)
  return self:sampleValues(r, frameFx, numFrame, interpolate, wrapFinal)[1]
end

-- Sample a scale channel (2-value keys). Returns { scale, inverseScale }.
function NitroCurve:sampleScale(r, frameFx, numFrame, interpolate, wrapFinal)
  local v = self:sampleValues(r, frameFx, numFrame, interpolate, wrapFinal)
  return { scale = v[1], inverseScale = v[2] }
end

NitroCurve.mul32 = mul32

return NitroCurve
