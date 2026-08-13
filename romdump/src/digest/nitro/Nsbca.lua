-- NSBCA (JNT0) joint animation decoder and sampler.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbca.s (pinned commit
-- 038cccaed, 2025-12-24), layout cross-verified against every NSBCA member
-- of the real HGSS field animation archive. Record layout (record-relative):
--
--   +0x00 u32 magic "J\0AC"   +0x04 u16 numFrame     +0x06 u16 numAnm
--   +0x08 u32 anmFlags  (bit 0: fractional-frame interpolation enabled;
--                         bit 1: final frame wraps toward key[0])
--   +0x0C u32 ofsRotData   pivot-rotation table (3 x u16 entries)
--   +0x10 u32 ofsPivotData compressed-rotation table (5 x u16 entries)
--   +0x14 u16 ofsTarget[numAnm]
--
-- Target flag word (per-target record at record + ofsTarget[i]):
--
--   bit  0: whole joint uses the model bind SRT (no channel data follows)
--   bits 1-2: translation mode (set: from model)
--   bits 3-5: transX/Y/Z constant (u32 fx32 each)
--   bits 6-7: rotation mode (set: from model)
--   bit  8:   rotation constant (one u32 key value)
--   bits 9-10: scale mode (set: from model)
--   bits 11-13: scaleX/Y/Z constant (u32 scale + u32 inverse each)
--   bits 16-23: raw, unnamed (preserved; zero in every field member)
--   bits 24-31: node index (0xFF = unused target)
--
-- Channels follow the flag tightly packed in fixed order: transX, transY,
-- transZ, rot, scaleX, scaleY, scaleZ -- each either absent (model mode),
-- a constant (4 bytes, or 8 for scale pairs), or an 8-byte
-- (u32 flag, u32 ofs) NitroCurve channel. Sampled rotation keys are always
-- u16.
--
-- The sampler mirrors NNSi_G3dAnmCalcNsBca + getJntSRTAnmResult_: the frame
-- is clamped to [0, numFrame << 12 - 1], fractional interpolation applies
-- only when anmFlags bit 0 is set and the frame has a fractional part, and
-- the integer path reproduces the odd-frame key merges (rotation merges
-- omit the final shift and rely on row normalization, exactly like the asm).
-- Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")
local NitroCurve = require("romdump.src.digest.nitro.NitroCurve")
local NitroRotation = require("romdump.src.digest.nitro.NitroRotation")

local Nsbca = {}

local MODEL = "model"
local CONSTANT = "constant"
local CURVE = "curve"

local F_WHOLE_MODEL = 0x001
local F_TRANS_MODE = 0x006
local F_TRANS_CONST = { 0x008, 0x010, 0x020 }
local F_ROT_FROM_MODEL = 0x040 -- rot fromModel gate: asm `ands r5, #0x40`; the 0x0C0 mode field is NOT the gate
local F_ROT_CONST = 0x100
local F_SCALE_MODE = 0x600
local F_SCALE_CONST = { 0x800, 0x1000, 0x2000 }
local AXES = { "x", "y", "z" }

local function bitSet(value, bit)
  return math.floor(value / bit) % 2 == 1
end

-- Any bit of `mask` set in `value`: the asm's ands mode gates. `mask` must
-- be a nonzero contiguous run of set bits (bitSet above is single-bit only
-- and must not be called with the mode masks).
local function maskAny(value, mask)
  assert(mask > 0, "mode mask must be nonzero")
  local shift = 1
  while mask % 2 == 0 do
    mask = math.floor(mask / 2)
    shift = shift * 2
  end
  local width = 2
  while math.floor(mask / 2) % 2 == 1 do
    width = width * 2
    mask = math.floor(mask / 2)
  end
  assert(mask == 1, "mode mask must span contiguous bits")
  return math.floor(value / shift) % width ~= 0
end

-- Cross product for the third row (cells 6-8 = row 0 x row 1), as the asm
-- computes it: 32-bit wraps, arithmetic shift by 12.
local function computeCross(cells)
  local m = NitroCurve.mul32
  local function wrap32(v)
    local p = v % 4294967296
    if p >= 2147483648 then
      p = p - 4294967296
    end
    return p
  end
  cells[7] = math.floor(wrap32(m(cells[2], cells[6]) - m(cells[3], cells[5])) / 4096)
  cells[8] = math.floor(wrap32(m(cells[3], cells[4]) - m(cells[1], cells[6])) / 4096)
  cells[9] = math.floor(wrap32(m(cells[1], cells[5]) - m(cells[2], cells[4])) / 4096)
end

-- Normalize one 3-vector row in place (VEC_Normalize). The SDK's exact
-- implementation (libsys) is not available; a double-precision normalize is
-- within the bind-pose equivalence tolerance. `offset` is 0-based.
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

-- Walk the fixed channel order of one target record, starting at `at` (the
-- flag word). Returns the decoded channels.
local function decodeChannels(r, flag, at, context)
  local channels = { trans = {}, rot = nil, scale = {} }

  if bitSet(flag, F_WHOLE_MODEL) then
    for _, axis in ipairs(AXES) do
      channels.trans[axis] = { source = MODEL }
      channels.scale[axis] = { source = MODEL }
    end
    channels.rot = { source = MODEL }
    return channels
  end

  for i = 1, 3 do
    local axis = AXES[i]
    -- Mode bits win over the constant bits, exactly like the asm (the
    -- encoder sets both for model-sourced channels).
    if maskAny(flag, F_TRANS_MODE) then
      channels.trans[axis] = { source = MODEL }
    elseif bitSet(flag, F_TRANS_CONST[i]) then
      r:assertRange(at, 4, "anm-const-trans")
      channels.trans[axis] = { source = CONSTANT, value = r:u32le(at) }
      at = at + 4
    else
      local curve = NitroCurve.decode(r, at, 1, context)
      at = at + 8
      channels.trans[axis] = { source = CURVE, curve = curve }
    end
  end

  if bitSet(flag, F_ROT_FROM_MODEL) then
    channels.rot = { source = MODEL }
  elseif bitSet(flag, F_ROT_CONST) then
    r:assertRange(at, 4, "anm-const-rot")
    channels.rot = { source = CONSTANT, value = r:u32le(at) }
    at = at + 4
  else
    local curve = NitroCurve.decode(r, at, 1, context)
    at = at + 8
    channels.rot = { source = CURVE, curve = curve }
  end

  if maskAny(flag, F_SCALE_MODE) then
    for _, axis in ipairs(AXES) do
      channels.scale[axis] = { source = MODEL }
    end
  else
    for i = 1, 3 do
      local axis = AXES[i]
      if bitSet(flag, F_SCALE_CONST[i]) then
        r:assertRange(at, 8, "anm-const-scale")
        channels.scale[axis] = { source = CONSTANT, value = r:u32le(at), inverse = r:u32le(at + 4) }
        at = at + 8
      else
        local curve = NitroCurve.decode(r, at, 2, context)
        at = at + 8
        channels.scale[axis] = { source = CURVE, curve = curve }
      end
    end
  end

  return channels
end

-- Decode the JNT0 record at `record` (absolute offset within the section
-- reader). Returns the animation resource. Use Nsbca.decode for files.
local function patchCurveBases(record, channels)
  local function fix(chan)
    if chan and chan.source == CURVE then
      chan.curve.keyBase = record + chan.curve.keyBase
    end
  end
  for _, axis in ipairs(AXES) do
    fix(channels.trans[axis])
  end
  fix(channels.rot)
  for _, axis in ipairs(AXES) do
    fix(channels.scale[axis])
  end
end

function Nsbca.decodeRecord(r, record, context)
  r:assertRange(record, 0x18, "nsbca-record-header")
  local numFrame = r:u16le(record + 0x04)
  local numAnm = r:u16le(record + 0x06)
  local anmFlags = r:u32le(record + 0x08)
  local ofsRotData = r:u32le(record + 0x0C)
  local ofsPivotData = r:u32le(record + 0x10)

  local targets = {}
  for i = 0, numAnm - 1 do
    local ofsTarget = r:u16le(record + 0x14 + i * 2)
    local at = record + ofsTarget
    r:assertRange(at, 4, "nsbca-target-flag")
    local flag = r:u32le(at)
    local channels = decodeChannels(r, flag, at + 4, context)
    patchCurveBases(record, channels)
    targets[#targets + 1] = {
      index = i,
      nodeIndex = math.floor(flag / 16777216) % 256,
      flagRaw = flag,
      channels = channels,
    }
  end

  return {
    numFrame = numFrame,
    numAnm = numAnm,
    anmFlags = anmFlags,
    ofsRotData = ofsRotData,
    ofsPivotData = ofsPivotData,
    record = record,
    targets = targets,
    source = context,
  }
end

-- Read one u16 rotation key.
local function readRotKey(r, curve, keyIndex)
  local at = curve.keyBase + keyIndex * 2
  r:assertRange(at, 2, "nsbca-rot-key")
  return r:u16le(at)
end

-- Reconstruct one key, applying the compressed-form cross product.
local function reconstructFinal(r, rotBase, compBase, key, context)
  local ra = NitroRotation.reconstruct(r, rotBase, compBase, key, context)
  local cells = {}
  for i = 1, 9 do
    cells[i] = ra.cells[i]
  end
  if ra.compressed then
    computeCross(cells)
  end
  return cells
end

-- Merge path for the integer sampler's odd frames: cells = weight * a + b
-- across both reconstructions (weight 1 for half rate, 3 for quarter rate),
-- then normalize the rows for the pivot form or cross-product the third
-- row for the compressed form.
local function mergeKeys(r, rotBase, compBase, keyA, keyB, weight, context)
  local ra = NitroRotation.reconstruct(r, rotBase, compBase, keyA, context)
  local rb = NitroRotation.reconstruct(r, rotBase, compBase, keyB, context)
  local cells = {}
  for i = 1, 9 do
    cells[i] = ra.cells[i] * weight + rb.cells[i]
  end
  if ra.compressed or rb.compressed then
    computeCross(cells)
  else
    normalizeRow(cells, 0)
    normalizeRow(cells, 3)
    normalizeRow(cells, 6)
  end
  return cells
end

-- Interpolating path: lerp cells 0-5 between two keys with the given step
-- and fractional part (32-bit muls, no final shift -- the asm omits it),
-- then normalize rows (pivot) or cross-product (compressed).
local function lerpKeys(r, rotBase, compBase, keyA, keyB, frac, step, context)
  local ra = NitroRotation.reconstruct(r, rotBase, compBase, keyA, context)
  local rb = NitroRotation.reconstruct(r, rotBase, compBase, keyB, context)
  local cells = {}
  local m = NitroCurve.mul32
  for i = 1, 6 do
    cells[i] = ra.cells[i] * step + math.floor(m(rb.cells[i] - ra.cells[i], frac) / 4096)
  end
  if ra.compressed or rb.compressed then
    computeCross(cells)
  else
    for i = 7, 9 do
      cells[i] = ra.cells[i] * step + math.floor(m(rb.cells[i] - ra.cells[i], frac) / 4096)
    end
    normalizeRow(cells, 0)
    normalizeRow(cells, 3)
    normalizeRow(cells, 6)
  end
  return cells
end

-- Sample the rotation channel at `frameFx` (already clamped).
local function sampleRot(r, res, rotChan, frameFx, context)
  local frame = math.floor(frameFx / 4096)
  local frac = frameFx % 4096
  local curve = rotChan.curve
  local rotBase = res.record + res.ofsRotData
  local compBase = res.record + res.ofsPivotData

  local function keyAt(index)
    return readRotKey(r, curve, index)
  end

  -- Ex path: fractional part present and interpolation enabled.
  if res.anmFlags % 2 == 1 and frac ~= 0 then
    if frame == res.numFrame - 1 then
      local index = frame
      if curve.rate == NitroCurve.HALF then
        index = frame % 2 + math.floor(frame / 2)
      elseif curve.rate == NitroCurve.QUARTER then
        index = frame % 4 + math.floor(frame / 4)
      end
      if math.floor(res.anmFlags / 2) % 2 == 1 then
        -- Wrap: interpolate key[last] toward key[0] with the 12-bit fraction.
        return lerpKeys(r, rotBase, compBase, keyAt(index), keyAt(0), frac, 1, context)
      end
      return reconstructFinal(r, rotBase, compBase, keyAt(index), context)
    end

    local index = math.floor(frame / curve.rate)
    local step = curve.rate
    local fracWide = frameFx % (4096 * curve.rate)
    if frame >= curve.limit then
      index = math.floor(curve.limit / curve.rate)
      fracWide = frac
      step = NitroCurve.FULL
    end
    return lerpKeys(r, rotBase, compBase, keyAt(index), keyAt(index + 1), fracWide, step, context)
  end

  -- Integer path.
  local rate = curve.rate
  local index = math.floor(frame / rate)
  if rate == NitroCurve.HALF then
    if frame % 2 == 1 then
      if frame > curve.limit then
        return reconstructFinal(r, rotBase, compBase, keyAt(math.floor(curve.limit / 2) + 1), context)
      end
      return mergeKeys(r, rotBase, compBase, keyAt(index), keyAt(index + 1), 1, context)
    end
    return reconstructFinal(r, rotBase, compBase, keyAt(index), context)
  elseif rate == NitroCurve.QUARTER then
    if frame % 4 ~= 0 then
      if frame > curve.limit then
        return reconstructFinal(r, rotBase, compBase, keyAt(frame % 4 + math.floor(curve.limit / 4)), context)
      end
      if frame % 4 == 2 then
        return mergeKeys(r, rotBase, compBase, keyAt(index), keyAt(index + 1), 1, context)
      end
      -- frame % 4 == 1 or 3: 3:1 weighting toward the nearer key.
      local a, b
      if frame % 4 == 1 then
        a, b = index, index + 1
      else
        a, b = index + 1, index
      end
      return mergeKeys(r, rotBase, compBase, keyAt(a), keyAt(b), 3, context)
    end
    return reconstructFinal(r, rotBase, compBase, keyAt(index), context)
  end
  return reconstructFinal(r, rotBase, compBase, keyAt(frame), context)
end

-- Sample one target at `frameFx` (fixed-point). Returns the joint result:
-- trans/rot/scale/inverseScale when animated (fx32 integers), and the
-- transFromModel/rotFromModel/scaleFromModel flags for channels the target
-- leaves to the model bind pose (the pose evaluator resolves those against
-- the model's node records).
function Nsbca.sample(r, res, targetIndex, frameFx)
  local target = assert(res.targets[targetIndex + 1], "target index " .. tostring(targetIndex) .. " out of range")
  -- NNSi_G3dAnmCalcNsBca clamps the frame into [0, numFrame << 12 - 1].
  local maxFx = res.numFrame * 4096 - 1
  if frameFx > maxFx then
    frameFx = maxFx
  end
  if frameFx < 0 then
    frameFx = 0
  end

  local ch = target.channels
  local interpolate = res.anmFlags % 2 == 1
  local wrapFinal = math.floor(res.anmFlags / 2) % 2 == 1
  local result = {
    trans = nil,
    rot = nil,
    scale = nil,
    inverseScale = nil,
    transFromModel = false,
    rotFromModel = false,
    scaleFromModel = false,
  }

  local trans, transModel = {}, false
  for _, axis in ipairs(AXES) do
    local c = ch.trans[axis]
    if c.source == MODEL then
      transModel = true
    elseif c.source == CONSTANT then
      trans[axis] = c.value
    else
      trans[axis] = NitroCurve.sample(c.curve, r, frameFx, res.numFrame, interpolate, wrapFinal)
    end
  end
  if transModel then
    result.transFromModel = true
  else
    result.trans = trans
  end

  local rot = ch.rot
  if rot.source == MODEL then
    result.rotFromModel = true
  elseif rot.source == CONSTANT then
    result.rot = reconstructFinal(r, res.record + res.ofsRotData, res.record + res.ofsPivotData, rot.value, res.source)
  else
    result.rot = sampleRot(r, res, rot, frameFx, res.source)
  end

  local scale, inverseScale, scaleModel = {}, nil, false
  for _, axis in ipairs(AXES) do
    local c = ch.scale[axis]
    if c.source == MODEL then
      scaleModel = true
    elseif c.source == CONSTANT then
      scale[axis] = c.value
      inverseScale = inverseScale or {}
      inverseScale[axis] = c.inverse
    else
      local pair = NitroCurve.sampleScale(c.curve, r, frameFx, res.numFrame, interpolate, wrapFinal)
      scale[axis] = pair.scale
      inverseScale = inverseScale or {}
      inverseScale[axis] = pair.inverseScale
    end
  end
  if scaleModel then
    result.scaleFromModel = true
  else
    result.scale = scale
  end
  result.inverseScale = inverseScale

  return result
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BCA0", context)
  if not file then
    error(err)
  end
  local section = NitroFile.section(file, "JNT0")
  if not section then
    error(Errors.new("NSBCA_NO_JNT0", "BCA0 file has no JNT0 section", { source = context }))
  end
  local r = BinaryReader.new(section.bytes, "jnt0")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local record = BinaryReader.new(entry.data, "nsbca-record"):u32le(0)
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = record,
      resource = Nsbca.decodeRecord(r, record, context),
    }
  end
  return {
    format = "NSBCA",
    section = section.magic,
    bytes = section.bytes,
    animations = animations,
    source = context,
  }
end

function Nsbca.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbca
