-- Nintendo DS backwards-LZ overlay decompression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local OverlayCompression = require("libs.rom.src.OverlayCompression")

local T = {}

-- OverlayCompression.decode returns its error unannotated, so err arrives
-- typed as the payload; cast to the Errors.Error contract the test has
-- already verified.
---@param e any
---@return Errors.Error
local function asError(e)
  return e
end

local function u8(v) return string.char(v % 256) end
local function u32(v)
  return u8(v) .. u8(math.floor(v / 256)) .. u8(math.floor(v / 65536))
    .. u8(math.floor(v / 16777216))
end

function T.decodes_literals_and_backward_match()
  -- Decodes three trailing A literals, then a 13-byte distance-3 match.
  local packed = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10)
    .. u32(0x0800000E) .. u32(2)
  Assert.equal(OverlayCompression.decode(packed, 16), string.rep("A", 16))
end

function T.rejects_expected_size_mismatch()
  local packed = u8(0) .. u8(0xA0) .. "AAA" .. u8(0x10)
    .. u32(0x0800000E) .. u32(2)
  local bytes, err = OverlayCompression.decode(packed, 17)
  Assert.isNil(bytes)
  Assert.equal(asError(err).code, "OVERLAY_COMPRESSION_SIZE_MISMATCH")
end

return T
