-- NSBTP (PAT0) texture/palette pattern animation decoder.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbtp.s + NNS_G3D_res_struct_acce.s
-- (pinned commit 038cccaed, 2025-12-24), layout cross-verified against the
-- 79 members of the real HGSS field archive (the stride and name-table
-- offsets were verified against raw bytes). Record layout
-- (record-relative):
--
--   +0x00 u32 size      +0x04 u16 numFrame
--   +0x06 u8 numTextures  +0x07 u8 numPalettes
--   +0x08 u16 ofsTexNames +0x0A u16 ofsPlttNames (16-byte names)
--   +0x0C u16 (numTargets in the high byte; low byte unnamed)
--   +0x12 u16 ofsTargetData
--   +0x14 u32 0x0000017F (constant across every member; unnamed)
--   at record + 0x0C + ofsTargetData:
--     +0x00 u16 stride       (uniform per-target record size)
--     +0x02 u16 ofsNameTable (target names, 16 bytes each)
--     per-target records at + 4 + stride * i:
--       +0x00 u32 keyCount   +0x04 s16 rate   +0x06 u16 ofsKeys
--     key arrays at record + ofsKeys: (u16 frame, u8 texIdx, u8 plttIdx)
--
-- Key selection (NNSi_G3dGetTexPatAnmFV): start at index
-- (rate * frame) >> 12, walk back while key[index].frame >= frame (floor 0)
-- and forward while key[index + 1].frame <= frame; the active key is the
-- last key whose frame does not exceed the requested frame. rate = 0x1000
-- divided by the frames per key (0x400 = one key every 4 frames). A
-- plttIdx of 0xFF means the key carries no palette change.
-- Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")

local Nsbtp = {}

local NAME_SIZE = 16

local function s16(value)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

-- Decode one per-target record: the key array plus the keyCount/rate header.
local function decodeTargetKeys(r, record, keyRecordAt)
  r:assertRange(keyRecordAt, 8, "nsbtp-key-record")
  local keyCount = r:u32le(keyRecordAt)
  local rate = s16(r:u16le(keyRecordAt + 4))
  local ofsKeys = r:u16le(keyRecordAt + 6)
  local keys = {}
  for i = 0, keyCount - 1 do
    local at = record + ofsKeys + i * 4
    r:assertRange(at, 4, "nsbtp-key")
    keys[#keys + 1] = {
      frame = r:u16le(at),
      texIdx = r:u8(at + 2),
      plttIdx = r:u8(at + 3),
    }
  end
  return { keyCount = keyCount, rate = rate, ofsKeys = ofsKeys, keys = keys }
end

-- Decode the PAT0 record at `record` (absolute within the section reader).
function Nsbtp.decodeRecord(r, record, context)
  r:assertRange(record, 0x1C, "nsbtp-record-header")
  local numFrame = r:u16le(record + 0x04)
  local numTextures = r:u8(record + 0x06)
  local numPalettes = r:u8(record + 0x07)
  local ofsTexNames = r:u16le(record + 0x08)
  local ofsPlttNames = r:u16le(record + 0x0A)
  local numTargets = r:u8(record + 0x0D)
  local ofsTargetData = r:u16le(record + 0x12)

  local tableAt = record + 0x0C + ofsTargetData
  r:assertRange(tableAt, 4, "nsbtp-target-table")
  local stride = r:u16le(tableAt)
  local ofsNameTable = r:u16le(tableAt + 2)

  local targets = {}
  for i = 0, numTargets - 1 do
    local keyRecordAt = tableAt + 4 + stride * i
    local name = r:ascii(tableAt + ofsNameTable + i * NAME_SIZE, NAME_SIZE, true)
    local keys = decodeTargetKeys(r, record, keyRecordAt)
    keys.index = i
    keys.name = name
    targets[#targets + 1] = keys
  end

  local function readNames(ofs, count)
    local names = {}
    for i = 0, count - 1 do
      names[#names + 1] = r:ascii(record + ofs + i * NAME_SIZE, NAME_SIZE, true)
    end
    return names
  end

  return {
    numFrame = numFrame,
    numTextures = numTextures,
    numPalettes = numPalettes,
    ofsTexNames = ofsTexNames,
    ofsPlttNames = ofsPlttNames,
    numTargets = numTargets,
    ofsTargetData = ofsTargetData,
    stride = stride,
    targets = targets,
    textureNames = readNames(ofsTexNames, numTextures),
    paletteNames = readNames(ofsPlttNames, numPalettes),
    record = record,
    source = context,
  }
end

-- The active key for `frame` (integer), per NNSi_G3dGetTexPatAnmFV. Returns
-- the key table entry. The initial index (rate * frame) >> 12 is clamped to
-- the last key; then the walk-back and walk-forward adjust it so the result
-- is the last key whose frame does not exceed the requested frame.
function Nsbtp.keyAt(res, targetIndex, frame)
  local target = assert(res.targets[targetIndex + 1], "target index " .. tostring(targetIndex) .. " out of range")
  local i = math.floor(target.rate * frame / 4096)
  if i >= target.keyCount then
    i = target.keyCount - 1
  end
  while i > 0 and target.keys[i].frame >= frame do
    i = i - 1
  end
  while i + 1 < target.keyCount and target.keys[i + 2].frame <= frame do
    i = i + 1
  end
  return target.keys[i + 1]
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BTP0", context)
  if not file then
    error(err)
  end
  local section = NitroFile.section(file, "PAT0")
  if not section then
    error(Errors.new("NSBTP_NO_PAT0", "BTP0 file has no PAT0 section", { source = context }))
  end
  local r = BinaryReader.new(section.bytes, "pat0")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local record = BinaryReader.new(entry.data, "nsbtp-record"):u32le(0)
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = record,
      resource = Nsbtp.decodeRecord(r, record, context),
    }
  end
  return { format = "NSBTP", section = section.magic, bytes = section.bytes, animations = animations, source = context }
end

function Nsbtp.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbtp
