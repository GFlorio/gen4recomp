-- TimeOfDayProps: the time-of-day field-prop policy (spec section 39). HGSS
-- registers up to four banded animations per field object -- morning, day,
-- evening, night -- and swaps the active band when the RTC time-of-day
-- changes (pokeheartgold overlay_01_02204004.c ov01_022047DC, with the
-- band map ov01_022095EC: MORN=0, DAY=1, EVE=2, NITE=3, LATE=3, and the hour
-- table sTimeOfDayByHour in gf_rtc.c GF_RTC_GetTimeOfDayByHour). A model
-- whose clips declare distinct bands by name suffix (_m/_d/_e/_n) is banded;
-- every other model keeps the ordinary ambient policy. The swap mirrors the
-- decomp's remove-and-add: stop the previous band's clip, play the current
-- band's clip looping. Pure domain module tests.

local Assert = require("tests.support.Assert")
local AnimationClip = require("libs.engine.src.AnimationClip")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local GenericModelFixture = require("tests.support.GenericModelFixture")
local ModelInstance = require("libs.engine.src.ModelInstance")
local TimeOfDayProps = require("libs.engine.src.TimeOfDayProps")

local T = {}

local function bandedClip(name)
  return AnimationClip.new({
    id = name,
    name = name,
    category = "joint",
    kind = "trs",
    frameCount = 8,
    tracks = {
      {
        target = 1,
        channels = {
          rotation = {
            interpolation = "linear",
            keys = {
              { frame = 0, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
              { frame = 7, value = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
            },
          },
        },
      },
    },
  })
end

local function bandedDefinition(clipNames)
  local def = GenericModelFixture.doorDefinition()
  local clips = {}
  for _, name in ipairs(clipNames) do
    clips[#clips + 1] = bandedClip(name)
  end
  return ModelDefinition.new({
    key = "fixture:sky",
    sourceBackend = def.sourceBackend,
    nodes = def.nodes,
    meshes = def.meshes,
    materials = def.materials,
    skins = def.skins,
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

function T.bands_are_the_four_in_band_order()
  Assert.deepEqual(TimeOfDayProps.bands(), { "morn", "day", "eve", "nite" })
end

-- ---- band classification ------------------------------------------------

function T.plan_maps_clips_to_bands_by_name_suffix()
  local def = bandedDefinition({ "kk_sky_m", "kk_sky_d", "kk_sky_e", "kk_sky_n" })
  local plan = assert(TimeOfDayProps.plan(def))
  Assert.equal(plan.morn.name, "kk_sky_m")
  Assert.equal(plan.day.name, "kk_sky_d")
  Assert.equal(plan.eve.name, "kk_sky_e")
  Assert.equal(plan.nite.name, "kk_sky_n")
end

function T.plan_is_nil_without_distinct_bands()
  -- No band suffixes at all (a door pair, or an ordinary effect).
  local def = GenericModelFixture.doorDefinition()
  Assert.isNil(TimeOfDayProps.plan(def))
  -- Two clips claiming one band (the m1/m2/n1/n2 light sets): ambiguous, so
  -- the model is not banded -- never guess the band order from slot order.
  local light = bandedDefinition({ "si_light_m1", "si_light_m2", "si_light_n1", "si_light_n2" })
  Assert.isNil(TimeOfDayProps.plan(light))
  -- A single banded clip is not a banded model.
  local single = bandedDefinition({ "kk_sky_m" })
  Assert.isNil(TimeOfDayProps.plan(single))
end

function T.plan_accepts_partial_band_sets()
  local def = bandedDefinition({ "o_moon_m1", "o_moon_n2" })
  local plan = assert(TimeOfDayProps.plan(def))
  Assert.equal(plan.morn.name, "o_moon_m1")
  Assert.equal(plan.nite.name, "o_moon_n2")
  Assert.isNil(plan.day)
  Assert.isNil(plan.eve)
end

-- ---- the swap -----------------------------------------------------------

local function playingNames(instance)
  local out = {}
  for _, category in ipairs({ "joint", "material", "visibility" }) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      out[#out + 1] = attachment.clip.name
    end
  end
  table.sort(out)
  return out
end

function T.swap_stops_the_old_band_and_plays_the_new()
  local def = bandedDefinition({ "kk_sky_m", "kk_sky_d", "kk_sky_e", "kk_sky_n" })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def)
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
  local def = bandedDefinition({ "o_moon_m1", "o_moon_n2" })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def)
  TimeOfDayProps.swap(instance, plan, nil, "nite")
  Assert.deepEqual(playingNames(instance), { "o_moon_n2" })
  TimeOfDayProps.swap(instance, plan, "nite", "day")
  Assert.deepEqual(playingNames(instance), {})
end

function T.swap_restarts_the_clip_from_frame_zero()
  local def = bandedDefinition({ "kk_sky_m", "kk_sky_d", "kk_sky_e", "kk_sky_n" })
  local plan = assert(TimeOfDayProps.plan(def))
  local instance = ModelInstance.new(def)
  TimeOfDayProps.swap(instance, plan, nil, "morn")
  for _ = 1, 5 do
    instance:updateFixed()
  end
  TimeOfDayProps.swap(instance, plan, "morn", "nite")
  local attachment = instance.animationState:attachments("joint")[1]
  Assert.equal(attachment.clip.name, "kk_sky_n")
  Assert.equal(attachment.player.frameFx, 0, "the new band starts from the first frame")
end

return T
