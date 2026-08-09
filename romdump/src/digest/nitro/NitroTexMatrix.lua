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
  if p >= 2147483648 then p = p - 4294967296 end
  return p
end

-- The 32-bit wrapped add/subtract (asm `add`/`sub`).
local function wrap32(v)
  local p = v % 4294967296
  if p >= 2147483648 then p = p - 4294967296 end
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

-- The variant index: the "one" flags (transOne = 1, rotOne = 2,
-- scaleOne = 4), matching `and r1, r1, #0x7` in the SendTexSRT shells.
local function variantIndex(srt)
  return (srt.transOne and 1 or 0) + (srt.rotOne and 2 or 0) + (srt.scaleOne and 4 or 0)
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
-- Variants are selected by (flags & 7): 0 = all components, then the absent
-- ones in the flag order, 7 = identity.

-- texmtxCalc_flag_ (all): NNS_G3D_maya.s 0x020BEBD8.
local function mayaTrs(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  local ts, tt = srt.transS, srt.transT
  local tsc = mulFx(ts, cos)
  local tss = mulFx(ts, sin)
  local tts = mulFx(tt, sin)
  local ttc = mulFx(tt, cos)
  return {
    tsc,
    asr(mul32(-tts, fxDiv(h, w)), 12),
    asr(mul32(tss, fxDiv(w, h)), 12),
    ttc,
    wrap32(shl(mul32(w, ts - (tss + tsc)), 3) - mul32(w, math.floor(ts * srt.scaleS / 256))),
    wrap32(mul32(h, math.floor(tt * srt.scaleT / 256)) + shl(mul32(h, (tts - ttc) - tt + 0x2000), 3)),
  }
end

-- texmtxCalc_flagS_ (rotation + scale): 0x020BEB00.
local function mayaRs(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  return {
    cos,
    asr(mul32(-sin, fxDiv(h, w)), 12),
    asr(mul32(sin, fxDiv(w, h)), 12),
    cos,
    wrap32(shl(mul32(w, 0x1000 - sin - cos), 3) - shl(mul32(srt.scaleS, w), 4)),
    wrap32(shl(mul32(h, 0x1000 + sin - cos), 3) + shl(mul32(srt.scaleT, h), 4)),
  }
end

-- texmtxCalc_flagR_ (translation + scale): 0x020BEA84.
local function mayaTs(srt)
  local w, h = srt.width, srt.height
  local ts, tt = srt.transS, srt.transT
  return {
    ts,
    0,
    0,
    tt,
    wrap32(-mul32(w, math.floor(ts * srt.scaleS / 256))),
    wrap32(mul32(h, math.floor(tt * srt.scaleT / 256)) + shl(mul32(h, 0x2000 - 2 * tt), 3)),
  }
end

-- texmtxCalc_flagRS_ (scale only): 0x020BEA3C.
local function mayaS(srt)
  return {
    0x1000,
    0,
    0,
    0x1000,
    shl(-mul32(srt.scaleS, srt.width), 4),
    shl(mul32(srt.scaleT, srt.height), 4),
  }
end

-- texmtxCalc_flagT_ (translation + rotation): 0x020BE954.
local function mayaTr(srt)
  local w, h = srt.width, srt.height
  local sin, cos = srt.sin, srt.cos
  local ts, tt = srt.transS, srt.transT
  local tsc = mulFx(ts, cos)
  local tss = mulFx(ts, sin)
  local tts = mulFx(tt, sin)
  local ttc = mulFx(tt, cos)
  return {
    tsc,
    asr(mul32(-tts, fxDiv(h, w)), 12),
    asr(mul32(tss, fxDiv(w, h)), 12),
    ttc,
    shl(mul32(w, ts - (tss + tsc)), 3),
    shl(mul32(h, (tts - ttc) - tt + 0x2000), 3),
  }
end

-- texmtxCalc_flagTS_ (rotation only): 0x020BE894.
local function mayaR(srt)
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

-- texmtxCalc_flagTR_ (translation only): 0x020BE850.
local function mayaT(srt)
  return {
    srt.transS,
    0,
    0,
    srt.transT,
    0,
    shl(mul32(srt.height, 0x2000 - 2 * srt.transT), 3),
  }
end

local MAYA_VARIANTS = {
  mayaTrs, mayaRs, mayaTs, mayaS, mayaTr, mayaR, mayaT,
  function() return { 0x1000, 0, 0, 0x1000, 0, 0 } end,
}

function NitroTexMatrix.maya(srt)
  return applyRatios(MAYA_VARIANTS[variantIndex(srt) + 1](srt), srt)
end

-- ---- Si3D (mode 1) ----

-- NNSi_G3dSendTexSRTSi3d (0x020BEF10): one inline build, no variant
-- dispatch. The convention maps the result fields differently from Maya:
-- the matrix's scale cells come from the trans slots, and the translation
-- cells combine the scale slots with the texture width/height.
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
      m00, m11 = srt.transS, srt.transT
    end
  elseif transOne then
    m00, m11 = 0x1000, 0x1000
    m20 = mul32(srt.width, wrap32(-shl(srt.scaleS, 4)))
    m21 = mul32(srt.height, wrap32(-shl(srt.scaleT, 4)))
  else
    m00, m11 = srt.transS, srt.transT
    m20 = mul32(srt.width, wrap32(-math.floor(srt.transS * srt.scaleS / 256)))
    m21 = mul32(srt.height, wrap32(-math.floor(srt.transT * srt.scaleT / 256)))
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
