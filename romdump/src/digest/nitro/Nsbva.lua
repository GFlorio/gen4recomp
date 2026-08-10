-- NSBVA (VIS0) node-visibility animation.
--
-- Authority: pokediamond arm9/asm/NNS_G3D_nsbva.s (pinned commit 038cccaed,
-- 2025-12-24). The record is a flat bit array: bit (frame * numAnm + node)
-- of the u32 words at record + 0x0C is the visibility of `node` at `frame`.
-- No interpolation, no constants -- the calc reads one bit. The HGSS field
-- animation archive contains no VIS0 members, so this decoder is exercised
-- by fixtures only. Record layout:
--
--   +0x00 u32 size      +0x04 u16 numFrame     +0x06 u16 numAnm
--   +0x0C u32 visibility[ceil(numFrame * numAnm / 32)]
-- Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")

local Nsbva = {}

-- Decode the VIS0 record at `record` (absolute within the section reader).
function Nsbva.decodeRecord(r, record, context)
  r:assertRange(record, 0x0C, "nsbva-record-header")
  local numFrame = r:u16le(record + 0x04)
  local numAnm = r:u16le(record + 0x06)
  local wordCount = math.ceil(numFrame * numAnm / 32)
  r:assertRange(record + 0x0C, wordCount * 4, "nsbva-visibility")
  local words = {}
  for i = 0, wordCount - 1 do
    words[i] = r:u32le(record + 0x0C + i * 4)
  end
  return {
    numFrame = numFrame,
    numAnm = numAnm,
    words = words,
    record = record,
    source = context,
  }
end

-- Visibility of `nodeIndex` at integer `frame` (0 = visible? 1 = visible;
-- the raw bit is returned). The frame is clamped to [0, numFrame - 1].
function Nsbva.sample(res, nodeIndex, frame)
  if frame < 0 then
    frame = 0
  end
  if frame >= res.numFrame then
    frame = res.numFrame - 1
  end
  local bit = frame * res.numAnm + nodeIndex
  local word = res.words[math.floor(bit / 32)]
  return math.floor(word / 2 ^ (bit % 32)) % 2 == 1
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BVA0", context)
  if not file then
    error(err)
  end
  local section = NitroFile.section(file, "VIS0")
  if not section then
    error(Errors.new("NSBVA_NO_VIS0", "BVA0 file has no VIS0 section", { source = context }))
  end
  local r = BinaryReader.new(section.bytes, "vis0")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local record = BinaryReader.new(entry.data, "nsbva-record"):u32le(0)
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = record,
      resource = Nsbva.decodeRecord(r, record, context),
    }
  end
  return { format = "NSBVA", section = section.magic, bytes = section.bytes, animations = animations, source = context }
end

function Nsbva.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Nsbva
