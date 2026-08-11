-- MapPropAnimCompiler playback-policy contract: every runtime playback
-- role is compiled from the decoded anim-list header (BuildModelAnimList),
-- never guessed from clip count. The game's ordinary registrar
-- (ov01_021E8F3C in tmp/refs/pokeheartgold/asm/overlay_01_021E8744.s)
-- registers and plays EVERY id slot of a record whose header is
-- registration=1, policy=0 (both bits clear), control=0 (the
-- never-finishing forward loop state, ov01_022044C8(-1, 0, 0)), areaGate=0
-- -- so every clip of such a record is an ambient loop, and no clip of any
-- other record is.
--
-- The time band of a clip is its slot in a banded record (policy 0x08),
-- mapped through the game's band map MORN=0 DAY=1 EVE=2 NITE=3
-- (overlay_01_02204004.c ov01_022095EC, consumed by the swap at
-- ov01_022047DC). The record policy -- not the clip name -- selects the
-- banded policy: door pairs and ambient effects never carry time-band
-- metadata, and two clips in one banded record can never be ambiguous
-- because every slot is unique.

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

-- An anim-list record with the given header bytes and resource ids.
-- Header fields (see BuildModelAnimList): registration (byte 0), policy
-- (byte 1), control (byte 2), areaGate (byte 3), reserved (bytes 4-5),
-- raw6 (byte 6), raw7 (byte 7).
local function record(registration, policy, control, areaGate, reserved, raw6, raw7, ids)
  local bw = BinaryWriter.new()
  bw:u8(registration)
  bw:u8(policy)
  bw:u8(control)
  bw:u8(areaGate)
  bw:u16(reserved)
  bw:u8(raw6)
  bw:u8(raw7)
  for _, id in ipairs(ids) do
    bw:u32(id)
  end
  for _ = 1, 4 - #ids do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  return bw:tostring()
end

-- Compile the record with one resource member per id. `resourceFor` picks
-- the fixture bytes per id; the default is the door pair.
local function compile(recordBytes, memberId, ids, resourceFor)
  local members = {}
  for _, id in ipairs(ids) do
    members[id] = resourceFor and resourceFor(id) or AnimationFixture.jntDoor()
  end
  return MapPropAnimCompiler.compile(recordBytes, resNarc(members), {
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

-- The ambient-policy header of the real corpus (New Bark wind, member 28):
-- registration 1, policy 0, control 0, area gate 0.
local function ambientHeader(raw6, ids)
  return record(1, 0, 0, 0, 0x0000, raw6, 1, ids)
end

function T.every_clip_of_an_ambient_policy_record_is_an_ambient_loop()
  -- Header 01 00 00 00 00 00 02 01: the ambient policy with TWO non-door
  -- clips (like the real as_yacht / fall_futago pairs). The ordinary
  -- registrar plays every slot of the record, so BOTH clips are ambient
  -- loops at load; a clip-count heuristic stamps none of them.
  local result = compile(ambientHeader(2, { 1, 2 }), 119, { 1, 2 }, function()
    return AnimationFixture.jntFull()
  end)
  Assert.equal(#result.clips, 2)
  Assert.isTrue(
    result.clips[1].ambientLoop,
    "the header policy says ambient: clip 1 of a two-clip record is an ambient loop"
  )
  Assert.isTrue(
    result.clips[2].ambientLoop,
    "the header policy says ambient: clip 2 of a two-clip record is an ambient loop"
  )
end

function T.load_only_records_never_play_at_load()
  -- Header 01 02 00 00 00 00 01 01 (real interior member 175, mg06_swc):
  -- policy bit 1 set -- the clips load but are NOT played at registration.
  -- A single clip must not carry the ambient-loop role that plays at load.
  local result = compile(record(1, 2, 0, 0, 0x0000, 1, 1, { 1 }), 175, { 1 }, function()
    return AnimationFixture.jntFull()
  end)
  Assert.equal(#result.clips, 1)
  Assert.isNil(result.clips[1].ambientLoop, "a load-only record (policy bit 1) never plays at load")
end

function T.door_policy_records_never_play_at_load()
  -- Header 01 03 00 00 00 00 01 01 (real interior members 11-14,
  -- moniter_mb / pc_mb / stair_pc_u01*): policy bit 0 set -- the record is
  -- registered by the interaction/door managers on demand, never by the
  -- ordinary registrar. A single clip must not carry the ambient-loop role.
  local result = compile(record(1, 3, 0, 0, 0x0000, 1, 1, { 1 }), 11, { 1 }, function()
    return AnimationFixture.jntFull()
  end)
  Assert.equal(#result.clips, 1)
  Assert.isNil(result.clips[1].ambientLoop, "a door-policy record (policy bit 0) is never an ambient loop")
end

function T.single_clip_ambient_records_keep_the_ambient_loop()
  -- Header 01 00 00 00 00 00 01 01 (New Bark wind, member 28): one clip,
  -- ambient policy -- the wind keeps playing at load.
  local result = compile(ambientHeader(1, { 6 }), 28, { 6 }, function()
    return AnimationFixture.srtWater()
  end)
  Assert.equal(#result.clips, 1)
  Assert.isTrue(result.clips[1].ambientLoop, "the wind's single clip stays an ambient loop")
end

function T.banded_record_stamps_bands_by_slot()
  -- HGSS banded props (e.g. kk_sky, the si_light pairs): header
  -- 01 08 00 00 00 00 04 01, and the four slots are the
  -- morning/day/evening/night animations regardless of their names.
  local result = compile(record(1, 8, 0, 0, 0x0000, 4, 1, { 1, 2, 3, 4 }), 113, { 1, 2, 3, 4 })
  Assert.deepEqual(bands(result), { "morn", "day", "eve", "nite" })
end

function T.banded_record_with_partial_slots_stamps_only_those_bands()
  local result = compile(record(1, 8, 0, 0, 0x0000, 2, 1, { 1, 2 }), 113, { 1, 2 })
  Assert.deepEqual(bands(result), { "morn", "day" })
end

function T.repeated_slot_names_are_not_ambiguous()
  -- The same clip name in two slots is two distinct band claims, not a
  -- conflict: each slot maps to its own band.
  local result = compile(record(1, 8, 0, 0, 0x0000, 4, 1, { 1, 1, 1, 1 }), 113, { 1 })
  Assert.deepEqual(bands(result), { "morn", "day", "eve", "nite" })
end

function T.time_band_clips_never_carry_the_ambient_role()
  -- The banded policy owns its clips entirely: the swap manager plays the
  -- current band, so no band slot is an ambient loop at load.
  local result = compile(record(1, 8, 0, 0, 0x0000, 4, 1, { 1, 2, 3, 4 }), 113, { 1, 2, 3, 4 })
  for _, clip in ipairs(result.clips) do
    Assert.isNil(clip.ambientLoop, "band slots are never ambient loops")
  end
end

function T.door_pairs_stay_unbanded_and_never_ambient()
  -- Header 01 03 00 01 01 00 01 02 (the door pair): policy bit 0 and the
  -- area gate set -- the door managers own the record. Door-named clips
  -- keep their roles, no time bands, and no ambient role.
  local result = compile(record(1, 3, 0, 1, 0x0001, 1, 2, { 1, 2 }), 26, { 1, 2 })
  Assert.equal(#result.clips, 2)
  Assert.isNil(result.clips[1].timeBand)
  Assert.isNil(result.clips[2].timeBand)
  Assert.isNil(result.clips[1].ambientLoop, "door clips never carry the ambient role")
  Assert.isNil(result.clips[2].ambientLoop, "door clips never carry the ambient role")
  Assert.equal(result.clips[1].semanticNames[1], "door.open")
end

function T.ambient_effects_stay_unbanded()
  -- Header 01 00 00 00 00 00 01 01 (a single ambient effect) carries no
  -- time band and keeps its ambient role.
  local result = compile(ambientHeader(1, { 1 }), 28, { 1 }, function()
    return AnimationFixture.jntFull()
  end)
  Assert.equal(#result.clips, 1)
  Assert.isNil(result.clips[1].timeBand)
  Assert.isTrue(result.clips[1].ambientLoop, "the ambient effect plays at load")
end

-- The ambient role moves from the clip-count heuristic to the decoded
-- header policy, so the compile semantics change: the clip-compile version
-- must bump, or the derived cache would serve stale clips.
function T.compiler_version_bumps_with_the_policy_semantics()
  Assert.equal(
    MapPropAnimCompiler.VERSION,
    "map-prop-anim-clip-v4",
    "the header-derived ambient policy bumps the clip-compile version"
  )
end

return T
