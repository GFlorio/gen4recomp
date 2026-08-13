-- Synthetic tests for the texture-matrix convention (Maya, transcribed from
-- the pinned pokediamond asm). Only the Maya (mode 0) convention is
-- supported; mode-1 materials raise at the evaluator. The raw static
-- texture-SRT decode (NsbmdMaterialSrt) is tested in
-- romdump/tests; this suite covers only the engine-side NitroTexMatrix
-- dispatch and matrix assembly.

local Assert = require("tests.support.Assert")
local NitroTexMatrix = require("libs.engine.src.NitroTexMatrix")

local T = {}

local function fx32(v)
  return math.floor(v * 65536) % 4294967296
end
local function fx16(v)
  local w = math.floor(v * 4096)
  if w < 0 then
    w = w + 65536
  end
  return w % 65536
end

-- ---- NitroTexMatrix: Maya ----
--
-- The dispatch variant is selected by the GetTexSRTAnm_ "one" flags
-- (bit 0 = scaleOne, bit 1 = rotOne, bit 2 = transOne) exactly like the
-- SendTexSRT shell's `and r1, r1, #0x7`. Every expectation below was
-- re-derived from the texmtxCalc_* asm bodies after the scale/translation
-- role correction; the scale slots feed the diagonal and rotation cells,
-- the translation slots feed the fold terms.

function T.maya_identity()
  local cells = NitroTexMatrix.maya({ transOne = true, rotOne = true, scaleOne = true })
  Assert.equal(cells[1], 0x1000)
  Assert.equal(cells[2], 0)
  Assert.equal(cells[3], 0)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[5], 0)
  Assert.equal(cells[6], 0)
end

function T.maya_rotation_only()
  -- 45 degrees: sin = 0x800, cos = 0xDD7 (0.8660), width 8, height 4.
  local srt = {
    transOne = true,
    scaleOne = true,
    sin = fx16(0.5),
    cos = fx16(0.8660),
    width = 8,
    height = 4,
  }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[1], fx16(0.8660))
  Assert.equal(cells[2], math.floor(NitroTexMatrix.mulFx(-fx16(0.5), 2048)))
  Assert.equal(cells[3], math.floor(NitroTexMatrix.mulFx(fx16(0.5), 8192)))
  Assert.equal(cells[4], fx16(0.8660))
  Assert.equal(cells[5], (8 * (0x1000 - fx16(0.5) - fx16(0.8660))) * 8)
  Assert.equal(cells[6], (4 * (0x1000 + fx16(0.5) - fx16(0.8660))) * 8)
end

function T.maya_scale_only()
  -- transOne + rotOne: flagTR_ -- the scale sits in the diagonal, with the
  -- (0x2000 - 2*scaleT) anchor term in c21.
  local srt = { transOne = true, rotOne = true, scaleS = 0x2000, scaleT = 0x1000, height = 4 }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[1], 0x2000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[2], 0)
  Assert.equal(cells[3], 0)
  Assert.equal(cells[5], 0)
  Assert.equal(cells[6], (4 * (0x2000 - 2 * 0x1000)) * 8)
end

function T.maya_translation_only()
  -- scaleOne + rotOne: flagRS_ -- translation folds into c20/c21 at
  -- 1/16-texel fixed point.
  local srt = { rotOne = true, scaleOne = true, transS = 0x1000, transT = 0x2000, width = 8, height = 4 }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[1], 0x1000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[2], 0)
  Assert.equal(cells[3], 0)
  Assert.equal(cells[5], -(0x1000 * 8) * 16)
  Assert.equal(cells[6], (0x2000 * 4) * 16)
end

function T.maya_scale_and_rotation()
  -- transOne: flagT_ -- the rotation cells are scale-multiplied, and the
  -- translation folds vanish.
  local srt = {
    transOne = true,
    scaleS = 0x2000,
    scaleT = 0x1000,
    sin = fx16(0.5),
    cos = fx16(0.8660),
    width = 8,
    height = 4,
  }
  local cells = NitroTexMatrix.maya(srt)
  local ssc = math.floor(0x2000 * fx16(0.8660) / 4096)
  local sss = math.floor(0x2000 * fx16(0.5) / 4096)
  local sts = math.floor(0x1000 * fx16(0.5) / 4096)
  local stc = math.floor(0x1000 * fx16(0.8660) / 4096)
  Assert.equal(cells[1], ssc)
  Assert.equal(cells[4], stc)
  Assert.equal(cells[2], math.floor(-sts * 2048 / 4096))
  Assert.equal(cells[3], math.floor(sss * 8192 / 4096))
  Assert.equal(cells[5], (8 * (0x2000 - sss - ssc)) * 8)
  Assert.equal(cells[6], (4 * (sts - stc - 0x1000 + 0x2000)) * 8)
end

function T.maya_scale_and_translation()
  -- rotOne: flagR_ -- scale diagonal plus the (scale * trans) >> 8 folds.
  local srt =
    { rotOne = true, scaleS = 0x2000, scaleT = 0x1000, transS = 0x1000, transT = 0x2000, width = 8, height = 4 }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[1], 0x2000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[2], 0)
  Assert.equal(cells[3], 0)
  Assert.equal(cells[5], -(8 * math.floor(0x2000 * 0x1000 / 256)))
  Assert.equal(cells[6], (4 * math.floor(0x1000 * 0x2000 / 256)) + (4 * (0x2000 - 2 * 0x1000)) * 8)
end

function T.maya_all_components()
  -- flag_: identity rotation (not flagged one) with animated scales and
  -- translations; the fold term appears alongside the rotation cells.
  local srt = {
    scaleS = 0x2000,
    scaleT = 0x1000,
    transS = 0x1000,
    transT = 0x2000,
    sin = 0,
    cos = 0x1000,
    width = 8,
    height = 4,
  }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[1], 0x2000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[2], 0)
  Assert.equal(cells[3], 0)
  Assert.equal(cells[5], -(8 * math.floor(0x2000 * 0x1000 / 256)))
  Assert.equal(cells[6], (4 * math.floor(0x1000 * 0x2000 / 256)) + (4 * (0 - 0x1000 - 0x1000 + 0x2000)) * 8)
end

function T.maya_ratios_apply()
  local srt = {
    rotOne = true,
    scaleOne = true,
    transS = 0x1000,
    transT = 0x2000,
    width = 8,
    height = 4,
    ratioS = 0x800,
    ratioT = 0x2000,
  }
  local cells = NitroTexMatrix.maya(srt)
  Assert.equal(cells[5], math.floor(-(0x1000 * 8) * 16 * 0x800 / 4096))
  Assert.equal(cells[6], math.floor((0x2000 * 4) * 16 * 0x2000 / 4096))
  -- The identity cells are scaled too.
  Assert.equal(cells[1], math.floor(0x1000 * 0x800 / 4096))
end

return T
