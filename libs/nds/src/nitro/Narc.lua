-- Pure reader over a NARC archive string. The block and member layout follows
-- pret/pokeheartgold's tools/o2narc/Narc.h and src/filesystem.c. A NARC is a 16-byte header
-- followed by blockCount blocks; BTAF holds the member allocation table, GMIF
-- the member data, BTNF optional names (unused by HGSS). Member offsets in BTAF
-- are relative to the GMIF payload and member IDs are zero based.
--
-- Only structural parsing happens here; members are never decompressed (a
-- separate Compression module owns that later). open() returns (narc | nil, err).

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

---@class Narc
---@field private _reader BinaryReader
---@field private _blocks table[]
---@field private _gmifOffset integer
---@field private _members table[]
local Narc = {}
Narc.__index = Narc

local HEADER_SIZE = 0x10
local BLOCK_HEADER_SIZE = 8
local UNIQUE_BLOCKS = { BTAF = true, BTNF = true, GMIF = true }

local function parseBlocks(reader, declaredSize, blockCount)
  local blocks, byMagic = {}, {}
  local offset = HEADER_SIZE
  for _ = 1, blockCount do
    if offset + BLOCK_HEADER_SIZE > declaredSize then
      Errors.raise(
        "NARC_BLOCK_PAST_END",
        "block header at " .. offset .. " extends past declared size " .. declaredSize,
        { offset = offset, declaredSize = declaredSize }
      )
    end
    local magic = reader:ascii(offset, 4)
    local size = reader:u32le(offset + 4)
    if size < BLOCK_HEADER_SIZE then
      Errors.raise(
        "NARC_BLOCK_TOO_SMALL",
        "block " .. magic .. " size " .. size .. " is below the " .. BLOCK_HEADER_SIZE .. "-byte minimum",
        { magic = magic, size = size }
      )
    end
    if offset + size > declaredSize then
      Errors.raise(
        "NARC_BLOCK_PAST_END",
        "block "
          .. magic
          .. " (offset "
          .. offset
          .. ", size "
          .. size
          .. ") extends past declared size "
          .. declaredSize,
        { magic = magic, offset = offset, size = size, declaredSize = declaredSize }
      )
    end
    if UNIQUE_BLOCKS[magic] and byMagic[magic] then
      Errors.raise("NARC_DUPLICATE_BLOCK", "duplicate " .. magic .. " block", { magic = magic })
    end
    local block = {
      magic = magic,
      offset = offset,
      size = size,
      payloadOffset = offset + BLOCK_HEADER_SIZE,
      payloadLength = size - BLOCK_HEADER_SIZE,
    }
    blocks[#blocks + 1] = block
    byMagic[magic] = block
    offset = offset + size
  end
  return blocks, byMagic
end

local function parseMembers(reader, btaf, gmif)
  local count = reader:u16le(btaf.payloadOffset)
  local members = {}
  for memberId = 0, count - 1 do
    local base = btaf.payloadOffset + 4 + memberId * 8
    local startOffset = reader:u32le(base)
    local endOffset = reader:u32le(base + 4)
    if startOffset > endOffset or endOffset > gmif.payloadLength then
      Errors.raise(
        "NARC_MEMBER_OUT_OF_RANGE",
        "member "
          .. memberId
          .. " range ["
          .. startOffset
          .. ", "
          .. endOffset
          .. ") exceeds GMIF payload of "
          .. gmif.payloadLength,
        { memberId = memberId, startOffset = startOffset, endOffset = endOffset, gmifSize = gmif.payloadLength }
      )
    end
    members[memberId + 1] = {
      memberId = memberId,
      startOffset = startOffset,
      endOffset = endOffset,
      size = endOffset - startOffset,
    }
  end
  return members
end

local function parse(data, label)
  local reader = BinaryReader.new(data, label or "narc")
  if reader:length() < HEADER_SIZE then
    Errors.raise(
      "NARC_TRUNCATED",
      "NARC is " .. reader:length() .. " bytes, need at least " .. HEADER_SIZE,
      { size = reader:length() }
    )
  end
  if reader:ascii(0, 4) ~= "NARC" then
    Errors.raise("NARC_BAD_MAGIC", "missing NARC magic", { magic = reader:ascii(0, 4) })
  end

  local declaredSize = reader:u32le(8)
  local blockCount = reader:u16le(14)
  if declaredSize > reader:length() then
    Errors.raise(
      "NARC_TRUNCATED",
      "declared size " .. declaredSize .. " exceeds supplied " .. reader:length() .. " bytes",
      { declaredSize = declaredSize, size = reader:length() }
    )
  end

  local blocks, byMagic = parseBlocks(reader, declaredSize, blockCount)
  if not byMagic.BTAF then
    Errors.raise("NARC_MISSING_BTAF", "NARC has no BTAF block")
  end
  if not byMagic.GMIF then
    Errors.raise("NARC_MISSING_GMIF", "NARC has no GMIF block")
  end

  local members = parseMembers(reader, byMagic.BTAF, byMagic.GMIF)
  return setmetatable({
    _reader = reader,
    _blocks = blocks,
    _gmifOffset = byMagic.GMIF.payloadOffset,
    _members = members,
  }, Narc)
end

function Narc.open(data, label)
  assert(type(data) == "string", "Narc.open requires a string")
  local ok, result = pcall(parse, data, label)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function Narc:memberCount()
  return #self._members
end

function Narc:memberInfo(memberId)
  local m = self._members[memberId + 1]
  if not m then
    return nil,
      Errors.new(
        "NARC_MEMBER_ID_OUT_OF_RANGE",
        "no member " .. tostring(memberId) .. " in NARC of " .. #self._members,
        { memberId = memberId, memberCount = #self._members }
      )
  end
  return { memberId = m.memberId, startOffset = m.startOffset, endOffset = m.endOffset, size = m.size }
end

function Narc:readMember(memberId)
  local m = self._members[memberId + 1]
  if not m then
    return nil,
      Errors.new(
        "NARC_MEMBER_ID_OUT_OF_RANGE",
        "no member " .. tostring(memberId) .. " in NARC of " .. #self._members,
        { memberId = memberId, memberCount = #self._members }
      )
  end
  return self._reader:bytes(self._gmifOffset + m.startOffset, m.size)
end

function Narc:blockInfo()
  local out = {}
  for i, b in ipairs(self._blocks) do
    out[i] = { magic = b.magic, offset = b.offset, size = b.size, payloadLength = b.payloadLength }
  end
  return out
end

-- Non-authoritative peek at a member's leading byte to guess Nintendo LZ
-- compression. Never mutates and never decompresses.
function Narc.detectCompression(data)
  if type(data) ~= "string" or #data == 0 then
    return nil
  end
  local kind = string.byte(data, 1)
  if kind == 0x10 then
    return "lz10"
  end
  if kind == 0x11 then
    return "lz11"
  end
  return nil
end

return Narc
