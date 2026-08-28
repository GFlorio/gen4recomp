-- Test helper: assemble SBNK embedded-resource bytes from instrument specs.
-- Layout follows the NitroSDK bank structures (SND_bank_shared.h): a 16-byte
-- NNS file header, a DATA block header, 0x18 bytes of wave-archive link
-- padding, a u32 instrument count at 0x38, packed u32 entries at 0x3C (type
-- low byte, record offset upper 24 bits from the bank start), then the
-- records. Direct records (types 1 PCM, 2 PSG, 3 noise) are a 10-byte
-- SNDInstParam (swav u16, swar slot u16, root key u8, four ADSR u8s, pan u8);
-- drum sets (0x10) are min/max keys plus 12-byte SNDInstData leaves; key
-- splits (0x11) are eight key bytes plus SNDInstData leaves.
--
-- Spec shapes:
--   { type = 1|2|3, param = { swav =, swarSlot =, rootKey =, attack =,
--     decay =, sustain =, release =, pan = } }
--   { type = 0x10, minKey =, maxKey =, leaves = { {type=, param=}, ... } }
--   { type = 0x11, keys = { 36, 48 }, leaves = { {type=, param=}, ... } }
--   { type = 0 } -- illegal/silent record
-- build() returns bytes, layout where layout.offsets[i] is the file offset of
-- record i (0-based instrument index). Test-only fixture.

local FntWriter = require("tests.support.FntWriter")

local SbnkFixture = {}

local function u8(v)
  return string.char(v % 256)
end
local u16, u32 = FntWriter.u16, FntWriter.u32

local INST_PCM = 1
local INST_PSG = 2
local INST_NOISE = 3
local INST_DIRECTPCM = 4
local INST_DUMMY = 5
local INST_DRUM_SET = 0x10
local INST_KEY_SPLIT = 0x11

local PARAM_SIZE = 10

local function paramBytes(param)
  assert(param, "instrument param required")
  return u16(param.swav or 0)
    .. u16(param.swarSlot or 0)
    .. u8(param.rootKey or 60)
    .. u8(param.attack or 127)
    .. u8(param.decay or 0)
    .. u8(param.sustain or 127)
    .. u8(param.release or 127)
    .. u8(param.pan or 64)
end

local function leafBytes(leaf)
  assert(
    leaf.type == INST_PCM
      or leaf.type == INST_PSG
      or leaf.type == INST_NOISE
      or leaf.type == INST_DIRECTPCM
      or leaf.type == INST_DUMMY
      or leaf.type == 0,
    "leaves must be PCM/PSG/noise or silent"
  )
  return u8(leaf.type) .. u8(0) .. paramBytes(leaf.param)
end

local function recordBytes(spec)
  local type = spec.type
  if type == 0 then
    return string.rep("\0", PARAM_SIZE)
  end
  if type == INST_PCM or type == INST_PSG or type == INST_NOISE or type == 4 or type == 5 then
    return paramBytes(spec.param)
  end
  if type == INST_DRUM_SET then
    assert(spec.minKey and spec.maxKey, "drum sets need minKey/maxKey")
    assert(#spec.leaves == spec.maxKey - spec.minKey + 1, "drum set leaf count must match its key range")
    local parts = { u8(spec.minKey), u8(spec.maxKey) }
    for _, leaf in ipairs(spec.leaves) do
      parts[#parts + 1] = leafBytes(leaf)
    end
    return table.concat(parts)
  end
  if type == INST_KEY_SPLIT then
    local keys = spec.keys or {}
    local parts = {}
    for i = 0, 7 do
      parts[#parts + 1] = u8(keys[i + 1] or 0)
    end
    for i, leaf in ipairs(spec.leaves) do
      assert(keys[i] ~= nil and keys[i] ~= 0, "key split leaves need non-zero keys")
      parts[#parts + 1] = leafBytes(leaf)
    end
    return table.concat(parts)
  end
  error("unknown fixture instrument type " .. tostring(type))
end

-- Builds the full embedded SBNK file bytes (NNS header + DATA block +
-- content with the instrument table and records).
---@param instruments table[]
---@return string
---@return table
function SbnkFixture.build(instruments)
  local body = {}
  local offsets = {}
  local cursor = 0x3C + #instruments * 4
  for index, spec in ipairs(instruments) do
    offsets[index - 1] = cursor
    local bytes = recordBytes(spec)
    body[#body + 1] = bytes
    cursor = cursor + #bytes
  end
  local entries = { u32(#instruments) }
  for index = 0, #instruments - 1 do
    -- Packed entry: type in the low byte, record offset in the upper 24 bits.
    local packed = instruments[index + 1].type + offsets[index] * 256
    entries[#entries + 1] = u32(packed)
  end
  local content = string.rep("\0", 0x20) .. table.concat(entries) .. table.concat(body)
  local dataBlock = "DATA" .. u32(#content + 8) .. content
  local file = "SBNK" .. u16(0xFEFF) .. u16(0x0100) .. u32(16 + #dataBlock) .. u16(0x10) .. u16(1) .. dataBlock
  return file, { offsets = offsets }
end

return SbnkFixture
