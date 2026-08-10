-- MapPropAnimCompiler band policy: the time band of a clip is its slot in the
-- banded anim-list record (record type with high byte 0x08), mapped through
-- the game's band map MORN=0 DAY=1 EVE=2 NITE=3 (overlay_01 ov01_022095EC,
-- consumed by the swap at ov01_022047DC). The record type -- not the clip
-- name -- selects the banded policy: door pairs and ambient effects never
-- carry time-band metadata, and two clips in one banded record can never be
-- ambiguous because every slot is unique.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.rom.src.BinaryWriter")
local AnimationFixture = require("tests.support.AnimationFixture")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")

local T = {}

local function resNarc(members)
  return {
    readMember = function(_, memberId)
      local bytes = assert(members[memberId], "no resource member " .. memberId)
      return bytes
    end,
  }
end

-- An anim-list record with the given header u16 and resource ids.
local function recordWithHeader(header, ids)
  local bw = BinaryWriter.new()
  bw:u16(header)
  bw:u16(0)
  bw:u32(0)
  for _, id in ipairs(ids) do
    bw:u32(id)
  end
  for _ = 1, 4 - #ids do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  return bw:tostring()
end

local function compile(record, memberId, ids)
  local members = {}
  for i, id in ipairs(ids) do
    members[id] = AnimationFixture.jntDoor()
  end
  return MapPropAnimCompiler.compile(record, resNarc(members), {
    archiveAlias = "exterior_build_anim_list",
    memberId = memberId,
  })
end

local function bands(result)
  local out = {}
  for _, clip in ipairs(result.clips) do
    out[#out + 1] = clip.timeBand
  end
  return out
end

function T.banded_record_stamps_bands_by_slot()
  -- HGSS banded props (e.g. kk_sky, the si_light pairs): the four slots are
  -- the morning/day/evening/night animations regardless of their names.
  local result = compile(recordWithHeader(0x0801, { 1, 2, 3, 4 }), 113, { 1, 2, 3, 4 })
  Assert.deepEqual(bands(result), { "morn", "day", "eve", "nite" })
end

function T.banded_record_with_partial_slots_stamps_only_those_bands()
  local result = compile(recordWithHeader(0x0801, { 1, 2 }), 113, { 1, 2 })
  Assert.deepEqual(bands(result), { "morn", "day" })
end

function T.repeated_slot_names_are_not_ambiguous()
  -- The same clip name in two slots is two distinct band claims, not a
  -- conflict: each slot maps to its own band.
  local result = compile(recordWithHeader(0x0801, { 1, 1, 1, 1 }), 113, { 1 })
  Assert.deepEqual(bands(result), { "morn", "day", "eve", "nite" })
end

function T.door_pairs_stay_unbanded()
  -- Type 0x0301 (door pairs) follows ordinary playback: no time bands, and
  -- door-named clips keep their door roles.
  local result = compile(recordWithHeader(0x0301, { 1, 2 }), 26, { 1, 2 })
  Assert.equal(#result.clips, 2)
  Assert.isNil(result.clips[1].timeBand)
  Assert.isNil(result.clips[2].timeBand)
  Assert.equal(result.clips[1].semanticNames[1], "door.open")
end

function T.ambient_effects_stay_unbanded()
  -- Type 0x0001 (a single ambient effect) carries no time band.
  local result = compile(recordWithHeader(0x0001, { 1 }), 28, { 1 })
  Assert.equal(#result.clips, 1)
  Assert.isNil(result.clips[1].timeBand)
end

return T
