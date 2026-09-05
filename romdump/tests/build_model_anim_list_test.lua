-- Decoder contract for one build-model animation-list record (a member of
-- the exterior_build_anim_list archive, HGSS a/1/0/7). Each record is a
-- fixed 0x18-byte slot: an 8-byte header whose first u16 is 0xFFFF when the
-- model has no animations, followed by a u32 array of resource ids that
-- index the shared build_anim archive (a/1/0/6). Unused id slots are
-- 0xFFFFFFFF.
--
-- The header decodes into a source-grounded record -- the bytes that have a
-- consumer meaning are named, the rest is not carried. decode() returns
-- { ids, registration, policy, control, areaGate, doorSoundType, banded } -- the fields
-- named by their consumer's meaning (the asm sources are in
-- BuildModelAnimList's header comment); banded = (policy == 0x08). The
-- no-animation sentinel (first header u16 0xFFFF) yields empty ids.

local Assert = require("tests.support.Assert")
local BuildModelAnimList = require("romdump.src.digest.model.BuildModelAnimList")

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

-- The named header fields every decode must carry, by byte offset.
local function assertHeader(r, registration, policy, control, areaGate)
  Assert.equal(r.registration, registration, "byte 0 registration gate")
  Assert.equal(r.policy, policy, "byte 1 policy bits")
  Assert.equal(r.control, control, "byte 2 control state")
  Assert.equal(r.areaGate, areaGate, "byte 3 area-loader gate")
end

function T.decodes_single_referenced_resource()
  -- Mirrors New Bark model 28 "wind": header 01 00 00 00 00 00 01 01, one
  -- referenced resource (id 6). The ambient policy: registration set,
  -- policy 0 (both bits clear), control 0 (the never-finishing loop), area
  -- gate clear.
  local r = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", { 6 }))
  Assert.equal(#r.ids, 1)
  Assert.equal(r.ids[1], 6)
  assertHeader(r, 1, 0, 0, 0)
  Assert.isFalse(r.banded, "ambient policy is not the time-band policy")
end

function T.decodes_multiple_referenced_resources()
  -- Mirrors model 26 "wk_door1": header 01 03 00 01 01 00 01 02, two joint
  -- animations (ids 1 and 2). The door policy: policy bits 0+1 set, area
  -- gate set -- the record never reaches the ordinary registrar.
  local r = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", { 1, 2 }))
  Assert.equal(#r.ids, 2)
  Assert.equal(r.ids[1], 1)
  Assert.equal(r.ids[2], 2)
  assertHeader(r, 1, 3, 0, 1)
  Assert.equal(r.doorSoundType, 1, "byte 4 door sound selector")
  Assert.isFalse(r.banded, "the door pair is not banded")
end

function T.no_animation_record_yields_no_ids()
  -- Non-animated models start with the 0xFFFF sentinel (byte 0 = 0xFF, not
  -- the 0x01 registration byte); the id region is all 0xFFFFFFFF, so no
  -- resources are referenced. The bytes are still exposed.
  local r = BuildModelAnimList.decode(record("\255\255\0\0\0\0\0\0", {}))
  Assert.equal(#r.ids, 0)
  assertHeader(r, 0xFF, 0xFF, 0, 0)
  Assert.isFalse(r.banded, "the sentinel is not banded")
end

function T.banded_records_carry_the_time_band_policy()
  -- HGSS marks time-of-day props with policy 0x08 (header 01 08 00 00 00
  -- 00 04 01): the game registers the ids as the four band slots
  -- (MORN/DAY/EVE/NITE, band map ov01_022095EC) and swaps them on RTC
  -- time-of-day changes (ov01_022047DC).
  local r = BuildModelAnimList.decode(record("\1\8\0\0\0\0\4\1", { 6, 7, 8, 9 }))
  assertHeader(r, 1, 8, 0, 0)
  Assert.equal(#r.ids, 4)
  Assert.isTrue(r.banded, "policy 0x08 selects the banded-prop policy")
end

function T.ordinary_records_are_not_banded()
  -- Door pairs (policy 3) and ambient effects (policy 0) follow ordinary
  -- playback; only policy 0x08 is banded.
  local door = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", { 1, 2 }))
  Assert.isTrue(not door.banded)
  local ambient = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", { 6 }))
  Assert.isTrue(not ambient.banded)
  local none = BuildModelAnimList.decode(record("\255\255\0\0\0\0\0\0", {}))
  Assert.isTrue(not none.banded)
end

function T.policy_bits_name_the_registrar_and_the_play_state()
  -- bit 0 (ov01_021E8864): the record is managed outside the ordinary
  -- registrar (doors, interaction props); bit 1 (ov01_021E887C): the clips
  -- load but are not played at registration.
  local door = BuildModelAnimList.decode(record("\1\3\0\1\1\0\1\2", {}))
  Assert.notNil(door.policy, "decode exposes byte 1 as the policy field")
  Assert.equal(door.policy % 2, 1, "door policy carries bit 0")
  Assert.equal(math.floor(door.policy / 2) % 2, 1, "door policy carries bit 1")
  local loadOnly = BuildModelAnimList.decode(record("\1\2\0\0\0\0\1\1", {}))
  Assert.equal(loadOnly.policy % 2, 0, "load-only policy has bit 0 clear")
  Assert.equal(math.floor(loadOnly.policy / 2) % 2, 1, "load-only policy carries bit 1")
  local ambient = BuildModelAnimList.decode(record("\1\0\0\0\0\0\1\1", {}))
  Assert.equal(ambient.policy, 0, "ambient policy has neither bit")
  local banded = BuildModelAnimList.decode(record("\1\8\0\0\0\0\4\1", {}))
  Assert.equal(banded.policy, 8, "the time-band policy is the 0x08 special case")
end

function T.decodes_door_sound_selector_without_claiming_later_bytes()
  -- Byte 4 is the door selector; bytes 5-7 remain unclaimed.
  local r = BuildModelAnimList.decode(record("\1\0\0\0\2\3\4\5", { 9 }))
  assertHeader(r, 1, 0, 0, 0)
  Assert.equal(r.doorSoundType, 2, "byte 4 is carried as the door selector")
  Assert.isNil(r.raw6, "byte 6 is not carried")
  Assert.isNil(r.raw7, "byte 7 is not carried")
end

function T.rejects_wrong_record_size()
  Assert.throws(function()
    BuildModelAnimList.decode("\0\0\0\0")
  end)
end

return { tests = T }
