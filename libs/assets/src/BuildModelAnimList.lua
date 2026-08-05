-- Decoder for one outdoor build-model animation-list record (a member of the
-- exterior_build_anim_list archive, HGSS a/1/0/7). Each record is a fixed
-- 0x18-byte slot: an 8-byte header whose first u16 is 0xFFFF when the model has
-- no animations, followed by a u32 array of resource ids that index the
-- exterior_build_anim archive (a/1/0/6). Unused id slots are 0xFFFFFFFF.
-- Layout observed from the HGSS field build-model animation list. Pure domain
-- module.

local BinaryReader = require("libs.rom.src.BinaryReader")

local BuildModelAnimList = {}

local RECORD_SIZE = 0x18
local ID_BASE = 0x08
local NONE = 0xFFFFFFFF

-- Decode one 0x18-byte record. Returns { ids = { <resourceId>, ... } } (empty
-- when the model has no animations).
function BuildModelAnimList.decode(bytes)
  assert(type(bytes) == "string", "BuildModelAnimList.decode requires a string")
  assert(#bytes == RECORD_SIZE,
    "build-model anim-list record must be " .. RECORD_SIZE .. " bytes, got " .. #bytes)
  local r = BinaryReader.new(bytes, "build-model-anim-list")

  local ids = {}
  for offset = ID_BASE, RECORD_SIZE - 4, 4 do
    local id = r:u32le(offset)
    if id == NONE then break end
    ids[#ids + 1] = id
  end
  return { ids = ids }
end

return BuildModelAnimList
