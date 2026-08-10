-- Decoder for one outdoor build-model animation-list record (a member of the
-- exterior_build_anim_list archive, HGSS a/1/0/7). Each record is a fixed
-- 0x18-byte slot: an 8-byte header whose first u16 is 0xFFFF when the model has
-- no animations, followed by a u32 array of resource ids that index the
-- shared build_anim archive (a/1/0/6). Unused id slots are 0xFFFFFFFF.
-- Layout observed from the HGSS field build-model animation list. Pure domain
-- module.
--
-- The header u16 is a record type, not merely a sentinel: its high byte
-- selects the game's animation policy (overlay_01's anim-list consumer,
-- ov01_021E8F3C). A type with high byte 0x08 is a time-of-day banded prop:
-- the game registers its ids as the four band slots -- MORN=0, DAY=1, EVE=2,
-- NITE=3 (band map ov01_022095EC) -- and swaps the active slot on RTC
-- time-of-day changes (ov01_022047DC). Every other type (0x0001 ambient
-- effects, 0x0201 specials, 0x0301 door pairs) follows ordinary playback.
-- decode() returns { ids = {...}, type = u16, banded = bool } (empty ids and
-- no type when the model has no animations; the first header u16 is 0xFFFF).

local BinaryReader = require("libs.codec.src.BinaryReader")

local BuildModelAnimList = {}

local RECORD_SIZE = 0x18
local ID_BASE = 0x08
local NONE = 0xFFFFFFFF
local NO_ANIM = 0xFFFF

-- Decode one 0x18-byte record. Returns { ids = { <resourceId>, ... }, type,
-- banded } (ids empty when the model has no animations; the first header u16
-- is then 0xFFFF and type/banded are nil).
function BuildModelAnimList.decode(bytes)
  assert(type(bytes) == "string", "BuildModelAnimList.decode requires a string")
  assert(#bytes == RECORD_SIZE, "build-model anim-list record must be " .. RECORD_SIZE .. " bytes, got " .. #bytes)
  local r = BinaryReader.new(bytes, "build-model-anim-list")

  local ids = {}
  -- The 0xFFFF header marks a model with no animation resources; resource
  -- id 0 is otherwise a valid member of the shared archive.
  local header = r:u16le(0)
  if header ~= NO_ANIM then
    for offset = ID_BASE, RECORD_SIZE - 4, 4 do
      local id = r:u32le(offset)
      if id == NONE then
        break
      end
      ids[#ids + 1] = id
    end
  end
  if header == NO_ANIM then
    return { ids = ids }
  end
  -- The game selects the time-of-day policy from the header's high byte
  -- (ov01_021E8F3C: byte 1 of the record compared against 8).
  return {
    ids = ids,
    type = header,
    banded = math.floor(header / 256) == 8,
  }
end

return BuildModelAnimList
