-- Nitro texture-matrix conventions: the per-convention math that turns a
-- texture-SRT state into the six texture-matrix cells the geometry engine
-- loads. The model's texMtxMode selects Maya (0), Si3D (1), 3ds Max (2) and
-- XSI (3); Diamond ships separate implementations and the conventions
-- genuinely differ, so no single generic UV formula is used.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_maya.s / NNS_G3D_si3d.s (pinned
-- commit 038cccaed, 2025-12-24), the texmtxCalc_* variants and the two
-- SendTexSRT shells. All HGSS field build models use mode 0 (Maya); Si3D is
-- implemented from the asm too; 3ds Max and XSI remain a transcription of
-- their texmtxCalc_* variants (their SendTexSRT shells are structurally
-- identical to Maya's).
--
-- Correction over the earlier transcription: the anm result's scale and
-- translation slots enter the cells in the asm order -- scaleS/scaleT at
-- +0x18/+0x1c feed the diagonal and rotation cells, transS/transT at
-- +0x24/+0x28 feed the translation folds -- and the "one" flags select the
-- dispatch variant (bit 0 = scaleOne, bit 1 = rotOne, bit 2 = transOne).
-- Every variant was re-verified against its asm body.
--
-- Input: { transS, transT, sin, cos, scaleS, scaleT, width, height } with
-- the "one" flags { transOne, rotOne, scaleOne } selecting the variant and
-- optional { ratioS, ratioT } texture-size ratios.
-- Output: the cells the shells write at buffer offsets
-- 0x00/0x04/0x10/0x14/0x30/0x34 (row stride 0x10): { c00, c01, c10, c11,
-- c20, c21 }. Pure domain module.

local NitroTexMatrix = {}

-- The 64-bit smull product shifted right 12 (the asm's
-- `smull lo, hi, ...; mov lo, lsr #0xc; orr lo, hi, lsl #0x14`).
local function mulFx(a, b)
  return math.floor(a * b / 4096)
end

-- The 32-bit wrapped multiply (asm `mul`).
local function mul32(a, b)
  local p = (a * b) % 4294967296
  if p >= 2147483648 then
    p = p - 4294967296
  end
  return p
end

-- The 32-bit wrapped add/subtract (asm `add`/`sub`).
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

-- The 32-bit wrapped left shift (asm `lsl`).
local function shl(value, bits)
  return wrap32(value * 2 ^ bits)
end

-- The DS FX_Div(n, d) as the shells use it: (n << 12) / d, truncated.
local function fxDiv(n, d)
  return math.floor(n * 4096 / d)
end

-- The variant index: the "one" flags (scaleOne = 1, rotOne = 2,
-- transOne = 4, the GetTexSRTAnm_ bit order), matching `and r1, r1, #0x7`
-- in the SendTexSRT shells.
local function variantIndex(srt)
  return (srt.scaleOne and 1 or 0) + (srt.rotOne and 2 or 0) + (srt.transOne and 4 or 0)
end

-- The SendTexSRT ratio pass shared by the Maya-family shells: multiply the
-- first column plus c20 by ratioS and the second column plus c21 by ratioT
-- when they differ from 0x1000.
local function applyRatios(cells, srt)
  if srt.ratioS and srt.ratioS ~= 0x1000 then
    cells[1] = mulFx(cells[1], srt.ratioS)
    cells[2] = mulFx(cells[2], srt.ratioS)
    cells[5] = mulFx(cells[5], srt.ratioS)
  end
  if srt.ratioT and srt.ratioT ~= 0x1000 then
    cells[3] = mulFx(cells[3], srt.ratioT)
    cells[4] = mulFx(cells[4], srt.ratioT)
    cells[6] = mulFx(cells[6], srt.ratioT)
  end
  return cells
end

-- ---- Maya (mode 0) ----
-- Variants are selected by (flags & 7), where the anm result's flag bits are
-- bit 0 = scaleOne, bit 1 = rotOne, bit 2 = transOne (GetTexSRTAnm_,
-- NNS_G3D_nsbta.s). The dispatch table is flag_ (0), flagS_ (1), flagR_ (2),
-- flagRS_ (3), flagT_ (4), flagTS_ (5), flagTR_ (6), flagTRS_ (7); each
-- name lists the components flagged "one", so e.g. flagS_ (scaleOne) builds
-- rotation + translation, and flagTRS_ is the identity.
--
-- The anm result carries scaleS/scaleT at +0x18/+0x1c, sin/cos at
-- +0x20/+0x22, transS/transT at +0x24/+0x28, and the current texture
-- width/height at +0x2c/+0x2e. The 64-bit smull products shift right 8 for
-- the scale/translation folds and right 12 for the rotation products.

-- The 64-bit smull product shifted right 8 (the asm's `smull; mov lsr #8;
-- orr hi lsl #24`): the scale/translation fold factor.
local function mulShr8(a, b)
  return math.floor(a * b / 256)
end

-- texmtxCalc_flag_ (all components): NNS_G3D_maya.s 0x020BEBD8.
local function mayaAll(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  local ts, tt = srt.transS, srt.transT
  local ss, st = srt.scaleS, srt.scaleT
  local ssc = mulFx(ss, cos)
  local sss = mulFx(ss, sin)
  local sts = mulFx(st, sin)
  local stc = mulFx(st, cos)
  return {
    ssc,
    asr(mul32(-sts, fxDiv(h, w)), 12),
    asr(mul32(sss, fxDiv(w, h)), 12),
    stc,
    wrap32(shl(mul32(w, ss - (sss + ssc)), 3) - mul32(w, mulShr8(ss, ts))),
    wrap32(mul32(h, mulShr8(st, tt)) + shl(mul32(h, (sts - stc) - st + 0x2000), 3)),
  }
end

-- texmtxCalc_flagS_ (scaleOne: rotation + translation): 0x020BEB00.
local function mayaRotTrans(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  local ts, tt = srt.transS, srt.transT
  return {
    cos,
    asr(mul32(-sin, fxDiv(h, w)), 12),
    asr(mul32(sin, fxDiv(w, h)), 12),
    cos,
    wrap32(shl(mul32(w, 0x1000 - sin - cos), 3) - shl(mul32(ts, w), 4)),
    wrap32(shl(mul32(h, 0x1000 + sin - cos), 3) + shl(mul32(tt, h), 4)),
  }
end

-- texmtxCalc_flagR_ (rotOne: scale + translation): 0x020BEA84.
local function mayaScaleTrans(srt)
  local w, h = srt.width, srt.height
  local ss, st = srt.scaleS, srt.scaleT
  local ts, tt = srt.transS, srt.transT
  return {
    ss,
    0,
    0,
    st,
    wrap32(-mul32(w, mulShr8(ss, ts))),
    wrap32(mul32(h, mulShr8(st, tt)) + shl(mul32(h, 0x2000 - 2 * st), 3)),
  }
end

-- texmtxCalc_flagRS_ (scaleOne + rotOne: translation only): 0x020BEA3C.
local function mayaTrans(srt)
  return {
    0x1000,
    0,
    0,
    0x1000,
    shl(-mul32(srt.transS, srt.width), 4),
    shl(mul32(srt.transT, srt.height), 4),
  }
end

-- texmtxCalc_flagT_ (transOne: scale + rotation): 0x020BE954.
local function mayaScaleRot(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  local ss, st = srt.scaleS, srt.scaleT
  local ssc = mulFx(ss, cos)
  local sss = mulFx(ss, sin)
  local sts = mulFx(st, sin)
  local stc = mulFx(st, cos)
  return {
    ssc,
    asr(mul32(-sts, fxDiv(h, w)), 12),
    asr(mul32(sss, fxDiv(w, h)), 12),
    stc,
    shl(mul32(w, ss - (sss + ssc)), 3),
    shl(mul32(h, (sts - stc) - st + 0x2000), 3),
  }
end

-- texmtxCalc_flagTS_ (transOne + scaleOne: rotation only): 0x020BE894.
local function mayaRot(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  return {
    cos,
    asr(mul32(-sin, fxDiv(h, w)), 12),
    asr(mul32(sin, fxDiv(w, h)), 12),
    cos,
    shl(mul32(w, 0x1000 - sin - cos), 3),
    shl(mul32(h, 0x1000 + sin - cos), 3),
  }
end

-- texmtxCalc_flagTR_ (transOne + rotOne: scale only): 0x020BE850.
local function mayaScale(srt)
  return {
    srt.scaleS,
    0,
    0,
    srt.scaleT,
    0,
    shl(mul32(srt.height, 0x2000 - 2 * srt.scaleT), 3),
  }
end

local MAYA_VARIANTS = {
  mayaAll,
  mayaRotTrans,
  mayaScaleTrans,
  mayaTrans,
  mayaScaleRot,
  mayaRot,
  mayaScale,
  function()
    return { 0x1000, 0, 0, 0x1000, 0, 0 }
  end,
}

function NitroTexMatrix.maya(srt)
  return applyRatios(MAYA_VARIANTS[variantIndex(srt) + 1](srt), srt)
end

-- ---- Si3D (mode 1) ----

-- NNSi_G3dSendTexSRTSi3d (0x020BEF10): one inline build, no variant
-- dispatch. The convention maps the result fields differently from Maya:
-- the matrix's scale cells come from the scale slots (the "one" flags are
-- the same GetTexSRTAnm_ bits), and the translation cells fold the
-- trans/scale products the same way as Maya's flag_/flagR_ variants.
--   cells: { m00, 0, 0, m11, m20, m21 } at 0x08/0x18/0x2c/0x30.
function NitroTexMatrix.si3d(srt)
  local scaleOne = srt.scaleOne
  local transOne = srt.transOne
  local m00, m11, m20, m21
  if scaleOne then
    m20, m21 = 0, 0
    if transOne then
      m00, m11 = 0x1000, 0x1000
    else
      m00, m11 = srt.scaleS, srt.scaleT
    end
  elseif transOne then
    m00, m11 = 0x1000, 0x1000
    m20 = wrap32(-shl(srt.transS, 4) * srt.width)
    m21 = wrap32(-shl(srt.transT, 4) * srt.height)
  else
    m00, m11 = srt.scaleS, srt.scaleT
    m20 = wrap32(-mul32(srt.width, mulShr8(srt.scaleS, srt.transS)))
    m21 = wrap32(-mul32(srt.height, mulShr8(srt.scaleT, srt.transT)))
  end
  local cells = { m00, 0, 0, m11, m20, m21 }
  if srt.ratioS and srt.ratioS ~= 0x1000 then
    cells[1] = mulFx(cells[1], srt.ratioS)
    cells[5] = mulFx(cells[5], srt.ratioS)
  end
  if srt.ratioT and srt.ratioT ~= 0x1000 then
    cells[4] = mulFx(cells[4], srt.ratioT)
    cells[6] = mulFx(cells[6], srt.ratioT)
  end
  return cells
end

NitroTexMatrix.mulFx = mulFx
NitroTexMatrix.fxDiv = fxDiv

return NitroTexMatrix
