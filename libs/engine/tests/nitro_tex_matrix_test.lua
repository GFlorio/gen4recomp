-- Synthetic tests for the Epic 2 material state: the static texture-SRT
-- extension decode and the texture-matrix conventions (Maya + Si3D,
-- transcribed from the pinned pokediamond asm).

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.rom.src.BinaryWriter")
local NitroBuilder = require("tests.support.NitroBuilder")
local NsbmdMaterialSrt = require("romdump.src.digest.nitro.NsbmdMaterialSrt")
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

-- ---- static texture-SRT decode ----

function T.srt_absent_components_return_nil()
  -- 0x1FCF: bits 1, 2 and 3 all set (scale, rotation, translation absent).
  local srt = NsbmdMaterialSrt.decode(0x1FCF, "\0\0\0\0")
  Assert.isNil(srt, "all components absent -> nil")
end

function T.srt_rotation_only()
  -- 0x1FCB: scale and translation absent, rotation present (gym lift style).
  local bytes = BinaryWriter.new()
  bytes:u16(fx16(0.5))
  bytes:u16(fx16(0.8660))
  local srt = assert(NsbmdMaterialSrt.decode(0x1FCB, bytes:tostring()))
  Assert.equal(srt.rot.sin, fx16(0.5))
  Assert.equal(srt.rot.cos, fx16(0.8660))
  Assert.equal(srt.scale, nil)
  Assert.equal(srt.trans, nil)
end

function T.srt_decodes_present_components()
  -- flags 0x1FC7: scale + rot absent, translation present (the water style).
  local bytes = BinaryWriter.new()
  bytes:u32(fx32(-68))
  bytes:u32(0)
  local srt = assert(NsbmdMaterialSrt.decode(0x1FC7, bytes:tostring()))
  Assert.equal(srt.scale, nil)
  Assert.equal(srt.rot, nil)
  Assert.equal(srt.trans.s, fx32(-68))
  Assert.equal(srt.trans.t, 0)
end

function T.srt_scale_and_translation()
  -- flags 0x1FC5: rot absent, scale + translation present.
  local bytes = BinaryWriter.new()
  bytes:u32(fx32(0.5))
  bytes:u32(fx32(1))
  bytes:u32(0)
  bytes:u32(fx32(1))
  local srt = assert(NsbmdMaterialSrt.decode(0x1FC5, bytes:tostring()))
  Assert.equal(srt.scale.s, fx32(0.5))
  Assert.equal(srt.scale.t, fx32(1))
  Assert.equal(srt.trans.t, fx32(1))
end

function T.srt_matrix_form()
  local bytes = string.rep("\0", 64)
  local srt = assert(NsbmdMaterialSrt.decode(0x3FCF, bytes))
  Assert.equal(#srt.matrix, 16)
  Assert.equal(srt.scale, nil)
end

function T.srt_malformed_extra_raises()
  local ok, err = pcall(NsbmdMaterialSrt.decode, 0x1FC5, "\0\0\0\0")
  Assert.isFalse(ok)
  Assert.equal(assert(err).code, "READ_OUT_OF_BOUNDS")
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

-- ---- NitroTexMatrix: Si3D ----

function T.si3d_all_present()
  local srt = { transS = 0x1000, transT = 0x2000, scaleS = 0x2000, scaleT = 0x1000, width = 8, height = 4 }
  local cells = NitroTexMatrix.si3d(srt)
  -- The scale slots feed the diagonal; the translation cells fold the
  -- scale/trans products.
  Assert.equal(cells[1], 0x2000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[5], -8 * math.floor(0x2000 * 0x1000 / 256))
  Assert.equal(cells[6], -4 * math.floor(0x1000 * 0x2000 / 256))
end

function T.si3d_trans_one()
  local srt = { transOne = true, transS = 0x2000, transT = 0x1000, width = 8, height = 4 }
  local cells = NitroTexMatrix.si3d(srt)
  Assert.equal(cells[1], 0x1000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[5], -(0x2000 * 8) * 16)
  Assert.equal(cells[6], -(0x1000 * 4) * 16)
end

function T.si3d_scale_one()
  local srt = { scaleOne = true, scaleS = 0x2000, scaleT = 0x1000, width = 8, height = 4 }
  local cells = NitroTexMatrix.si3d(srt)
  Assert.equal(cells[1], 0x2000)
  Assert.equal(cells[4], 0x1000)
  Assert.equal(cells[5], 0)
  Assert.equal(cells[6], 0)
end

return T
