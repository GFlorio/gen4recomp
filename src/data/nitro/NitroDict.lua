-- Generic Nitro 3D resource dictionary (NNSG3dResDict): the name->data table
-- used by model, texture, palette, node, material and shape lists. Layout from
-- pokeheartgold res_struct.h / res_struct_accessor_inline.h:
--
--   +0x00 u8  revision
--   +0x01 u8  numEntry (N)
--   +0x02 u16 sizeDictBlk
--   +0x04 u16 dummy
--   +0x06 u16 ofsEntry          ; from dict start to the entry-data section
--   +0x08 (N+1) Patricia nodes  ; 4 bytes each, not used for lookup here
--   entry section (dict + ofsEntry):
--     +0x00 u16 sizeUnit        ; bytes per entry data unit (self-describing)
--     +0x02 u16 ofsName         ; from entry section to the 16-byte name list
--     +0x04 data[N * sizeUnit]
--     names[N * 16] at (entry section + ofsName)
--
-- Per spec the Patricia tree is preserved but not walked; names come from the
-- entry list and duplicate decoded names are rejected. Offsets in returned
-- entries are absolute within the supplied buffer. Pure domain module.

local Errors = require("src.import.Errors")
local BinaryReader = require("src.import.BinaryReader")

local NitroDict = {}

local NAME_SIZE = 16

local function raise(code, message, context)
  error(Errors.new(code, message, context))
end

local function _decode(bytes, base, context)
  assert(type(bytes) == "string", "NitroDict.decode requires a string")
  base = base or 0
  local r = BinaryReader.new(bytes, "nitro-dict")
  r:assertRange(base, 8, "dict-header")

  local revision = r:u8(base + 0x00)
  local count = r:u8(base + 0x01)
  local size = r:u16le(base + 0x02)
  local ofsEntry = r:u16le(base + 0x06)

  local treeStart = base + 8
  local treeBytes = r:bytes(treeStart, (count + 1) * 4)

  local entryBase = base + ofsEntry
  r:assertRange(entryBase, 4, "dict-entry-header")
  local sizeUnit = r:u16le(entryBase)
  local ofsName = r:u16le(entryBase + 2)
  local dataStart = entryBase + 4
  local nameStart = entryBase + ofsName

  local entries = {}
  local byName = {}
  for index = 0, count - 1 do
    local dataOffset = dataStart + index * sizeUnit
    local data = r:bytes(dataOffset, sizeUnit)
    local name = r:ascii(nameStart + index * NAME_SIZE, NAME_SIZE, true)
    if byName[name] then
      raise("NITRO_DICT_DUPLICATE_NAME",
        string.format("duplicate dictionary name %q at index %d", name, index),
        { name = name, index = index, source = context })
    end
    local entry = { index = index, name = name, data = data, dataOffset = dataOffset }
    entries[#entries + 1] = entry
    byName[name] = entry
  end

  return {
    revision = revision,
    count = count,
    size = size,
    ofsEntry = ofsEntry,
    sizeUnit = sizeUnit,
    nodes = treeBytes,
    entries = entries,
    byName = byName,
    source = context,
  }
end

function NitroDict.decode(bytes, base, context)
  local ok, result = pcall(_decode, bytes, base, context)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return NitroDict
