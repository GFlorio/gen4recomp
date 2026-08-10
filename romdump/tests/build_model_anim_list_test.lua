local Assert = require("tests.support.Assert")
local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")

local T = {}

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- 0x18-byte record: 8-byte header, then u32 ids padded with 0xFFFFFFFF.
local function record(header, ids)
  local parts = { header }
  for _, id in ipairs(ids) do
    parts[#parts + 1] = u32(id)
  end
  local body = table.concat(parts)
  return body .. string.rep("\255", 0x18 - #body)
end

function T.decodes_single_referenced_resource()
  -- Mirrors New Bark model 28 "wind": one referenced resource (id 6).
  local r = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", { 6 }))
  Assert.equal(#r.ids, 1)
  Assert.equal(r.ids[1], 6)
end

function T.decodes_multiple_referenced_resources()
  -- Mirrors model 24 "wk_door1": two joint animations (ids 1 and 2).
  local r = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", { 1, 2 }))
  Assert.equal(#r.ids, 2)
  Assert.equal(r.ids[1], 1)
  Assert.equal(r.ids[2], 2)
end

function T.no_animation_record_yields_no_ids()
  -- Non-animated models start with the 0xFFFF sentinel; the id region is all
  -- 0xFFFFFFFF, so no resources are referenced.
  local r = BuildModelAnimList.decode(record("\255\255\0\0\0\0\0\0", {}))
  Assert.equal(#r.ids, 0)
end

function T.banded_records_carry_the_game_s_band_slot_type()
  -- HGSS marks time-of-day props with the 0x0801 record type: the game
  -- registers the ids as the four band slots (MORN/DAY/EVE/NITE, band map
  -- ov01_022095EC) and swaps them on RTC changes (ov01_022047DC).
  local r = BuildModelAnimList.decode(record("\1\8\0\0\0\0\0\0", { 6, 7, 8, 9 }))
  Assert.equal(r.type, 0x0801)
  Assert.isTrue(r.banded, "type byte 0x08 selects the banded-prop policy")
  Assert.equal(#r.ids, 4)
end

function T.ordinary_records_are_not_banded()
  -- Door pairs (0x0301) and ambient effects (0x0001) follow ordinary playback.
  local door = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", { 1, 2 }))
  Assert.equal(door.type, 0x0301)
  Assert.isTrue(not door.banded)
  local ambient = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", { 6 }))
  Assert.equal(ambient.type, 0x0001)
  Assert.isTrue(not ambient.banded)
  local none = BuildModelAnimList.decode(record("\255\255\0\0\0\0\0\0", {}))
  Assert.isTrue(not none.banded)
end

function T.rejects_wrong_record_size()
  Assert.throws(function()
    BuildModelAnimList.decode("\0\0\0\0")
  end)
end

return { tests = T }
