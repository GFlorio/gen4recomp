-- Synthetic tests for the static texture-SRT extension decode (NsbmdMaterialSrt,
-- the romdump-side decoder that turns raw material texImageParam flag words
-- and SRT payload bytes into the normalized records the engine's
-- NitroTexMatrix conventions consume).

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local NitroBuilder = require("tests.support.NitroBuilder")
local NsbmdMaterialSrt = require("romdump.src.digest.nitro.NsbmdMaterialSrt")

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

return T
