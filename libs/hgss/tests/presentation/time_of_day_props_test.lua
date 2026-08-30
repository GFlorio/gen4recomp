-- TimeOfDayProps: the time-of-day field-prop policy. HGSS registers up to
-- four banded animations per field object -- morning, day, evening, night --
-- and swaps the active band when the RTC time-of-day changes (pokeheartgold
-- overlay_01_02204004.c ov01_022047DC, with the band map ov01_022095EC:
-- MORN=0, DAY=1, EVE=2, NITE=3, LATE=3, and the hour table sTimeOfDayByHour
-- in gf_rtc.c GF_RTC_GetTimeOfDayByHour). Band membership is compiled
-- metadata (clip.timeBand); the plan never infers policy from names or clip
-- counts. The swap mirrors the decomp's remove-and-add: stop the previous
-- band's clip, play the current band's clip looping. Pure domain module
-- tests.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local NitroModelFixture = require("tests.support.NitroModelFixture")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")
local TimeOfDayProps = require("libs.hgss.src.presentation.TimeOfDayProps")

local T = {}

---@class TimeOfDayPropsTest.AnimationState
---@field attachments fun(self: TimeOfDayPropsTest.AnimationState, category: string): table[]
---@class TimeOfDayPropsTest.Instance : TimeOfDayProps.Instance
---@field animationState TimeOfDayPropsTest.AnimationState
---@field updateFixed fun(self: TimeOfDayPropsTest.Instance)

local function bandedClip(name, band)
  return {
    id = "fixture:" .. name,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = { { target = 0, targetIndex = 0 } },
    semanticNames = {},
    source = { type = "nitro", format = "NSBCA", archive = "build_anim", memberId = 1 },
    timeBand = band,
    compiled = {
      anmFlags = 0,
      rotData = {},
      pivotData = {},
      targets = { { nodeIndex = 0, channels = {} } },
    },
  }
end

local function bandedDefinition(clips)
  local def = NitroModelFixture.doorDefinition(clips)
  return ModelDefinition.new({
    key = "fixture:sky",
    nodes = def.nodes,
    meshes = def.meshes,
    materials = def.materials,
    animations = clips,
    backend = def.backend,
  })
end

-- ---- the HGSS hour table -----------------------------------------------

function T.band_for_hour_matches_the_hgss_table()
  Assert.equal(TimeOfDayProps.bandForHour(0), "nite")
  Assert.equal(TimeOfDayProps.bandForHour(3), "nite")
  Assert.equal(TimeOfDayProps.bandForHour(4), "morn")
  Assert.equal(TimeOfDayProps.bandForHour(9), "morn")
  Assert.equal(TimeOfDayProps.bandForHour(10), "day")
  Assert.equal(TimeOfDayProps.bandForHour(16), "day")
  Assert.equal(TimeOfDayProps.bandForHour(17), "eve")
  Assert.equal(TimeOfDayProps.bandForHour(19), "eve")
  Assert.equal(TimeOfDayProps.bandForHour(20), "nite")
  Assert.equal(TimeOfDayProps.bandForHour(23), "nite")
end

function T.band_for_seconds_derives_the_hour()
  Assert.equal(TimeOfDayProps.bandForSeconds(6 * 3600), "morn")
  Assert.equal(TimeOfDayProps.bandForSeconds(43200), "day")
  Assert.equal(TimeOfDayProps.bandForSeconds(18 * 3600 + 120), "eve")
  Assert.equal(TimeOfDayProps.bandForSeconds(22 * 3600), "nite")
end

function T.bands_are_the_animation_contracts_table_in_band_order()
  -- One vocabulary owner: BANDS IS the animation contract's table (not a
  -- copy), and the copy function is gone.
  local AnimationClip = require("libs.assets.src.AnimationClip")
  Assert.equal(TimeOfDayProps.BANDS, AnimationClip.BANDS, "BANDS references the shared animation contract table")
  Assert.deepEqual(TimeOfDayProps.BANDS, { "morn", "day", "eve", "nite" })
  Assert.isNil(TimeOfDayProps.bands, "bands() is gone; consumers iterate BANDS")
end

-- ---- band classification ------------------------------------------------

function T.plan_maps_compiled_band_metadata()
  local def = bandedDefinition({
    bandedClip("kk_sky_m", "morn"),
    bandedClip("kk_sky_d", "day"),
    bandedClip("kk_sky_e", "eve"),
    bandedClip("kk_sky_n", "nite"),
  })
  local plan = assert(TimeOfDayProps.plan(def))
  Assert.equal(plan.morn.name, "kk_sky_m")
  Assert.equal(plan.day.name, "kk_sky_d")
  Assert.equal(plan.eve.name, "kk_sky_e")
  Assert.equal(plan.nite.name, "kk_sky_n")
end

function T.plan_is_nil_without_band_metadata()
  -- No compiled band metadata at all (a door pair, or an ordinary effect).
  local def = NitroModelFixture.doorDefinition()
  Assert.isNil(TimeOfDayProps.plan(def))
end

function T.plan_accepts_partial_band_sets()
  local def = bandedDefinition({
    bandedClip("o_moon_m1", "morn"),
    bandedClip("o_moon_n2", "nite"),
  })
  local plan = assert(TimeOfDayProps.plan(def))
  Assert.equal(plan.morn.name, "o_moon_m1")
  Assert.equal(plan.nite.name, "o_moon_n2")
  Assert.isNil(plan.day)
  Assert.isNil(plan.eve)
end

function T.plan_rejects_duplicate_band_claims()
  -- Bands come from the banded record's unique slots, so a plan that sees a
  -- duplicate has a corrupted descriptor; that is a programming error.
  local def = bandedDefinition({
    bandedClip("si_light_m1", "morn"),
    bandedClip("si_light_m2", "morn"),
  })
  local ok = pcall(TimeOfDayProps.plan, def)
  Assert.isFalse(ok, "a duplicated band claim is a contract violation")
end

-- ---- the swap -----------------------------------------------------------

---@param instance TimeOfDayPropsTest.Instance
---@return string[]
local function playingNames(instance)
  local out = {}
  for _, category in ipairs({ "joint", "material" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      out[#out + 1] = attachment.clip.name
    end
  end
  table.sort(out)
  return out
end

function T.swap_stops_the_old_band_and_plays_the_new()
  local def = bandedDefinition({
    bandedClip("kk_sky_m", "morn"),
    bandedClip("kk_sky_d", "day"),
    bandedClip("kk_sky_e", "eve"),
    bandedClip("kk_sky_n", "nite"),
  })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def) --[[@as TimeOfDayPropsTest.Instance]]
  TimeOfDayProps.swap(instance, plan, nil, "morn")
  Assert.deepEqual(playingNames(instance), { "kk_sky_m" })

  -- The day clip starts at frame 0 and advances; the morning clip is gone.
  TimeOfDayProps.swap(instance, plan, "morn", "day")
  Assert.deepEqual(playingNames(instance), { "kk_sky_d" })
  instance:updateFixed()
  instance:updateFixed()
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.player.frameFx, 2 * 4096)
end

function T.swap_to_a_band_without_a_clip_stops_playback()
  local def = bandedDefinition({
    bandedClip("o_moon_m1", "morn"),
    bandedClip("o_moon_n2", "nite"),
  })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def) --[[@as TimeOfDayPropsTest.Instance]]
  TimeOfDayProps.swap(instance, plan, nil, "nite")
  Assert.deepEqual(playingNames(instance), { "o_moon_n2" })
  TimeOfDayProps.swap(instance, plan, "nite", "day")
  Assert.deepEqual(playingNames(instance), {})
end

function T.swap_restarts_the_clip_from_frame_zero()
  local def = bandedDefinition({
    bandedClip("kk_sky_m", "morn"),
    bandedClip("kk_sky_d", "day"),
    bandedClip("kk_sky_e", "eve"),
    bandedClip("kk_sky_n", "nite"),
  })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def) --[[@as TimeOfDayPropsTest.Instance]]
  TimeOfDayProps.swap(instance, plan, nil, "morn")
  for _ = 1, 5 do
    instance:updateFixed()
  end
  TimeOfDayProps.swap(instance, plan, "morn", "nite")
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.clip.name, "kk_sky_n")
  Assert.equal(attachment.player.frameFx, 0, "the new band starts from the first frame")
end

return { tests = T }
