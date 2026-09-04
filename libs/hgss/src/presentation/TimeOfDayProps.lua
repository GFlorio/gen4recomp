-- TimeOfDayProps: the time-of-day field-prop policy. HGSS registers up to
-- four banded animations per field object -- morning, day, evening, night --
-- and swaps the active band when the RTC time-of-day changes (pokeheartgold
-- src/field/overlay_01_02204004.c ov01_022047DC, with the band map
-- ov01_022095EC: MORN=0, DAY=1, EVE=2, NITE=3, LATE=3, and the hour table
-- sTimeOfDayByHour in src/gf_rtc.c GF_RTC_GetTimeOfDayByHour).
--
-- A model is banded when its compiled clips carry time-band metadata
-- (clip.timeBand, stamped by MapPropAnimCompiler from the banded anim-list
-- record's slot order, the decomp's band map); a plan never infers policy
-- from names or clip counts. The swap mirrors the decomp's remove-and-add: stop the
-- previous band's clip, play the current band's clip looping. Every other
-- model follows the ordinary ambient policy (every clip of an
-- ordinary-policy anim-list record carries the compiled ambientLoop role).
-- Pure domain module.

-- The four bands in HGSS band-slot order, owned by the animation contract
-- (AnimationClip.BANDS): the digest stamps clip.timeBand from the same table
-- (ov01_022095EC indices 0-3; LATE maps to the NITE slot).
local AnimationClip = require("libs.assets.src.model.AnimationClip")

local TimeOfDayProps = {}

---@class TimeOfDayProps.Clip
---@field name string
---@field timeBand string?

---@class TimeOfDayProps.Instance: ModelInstance

TimeOfDayProps.BANDS = AnimationClip.BANDS

-- Band by hour, transcribed from sTimeOfDayByHour (gf_rtc.c): 0-3 LATE,
-- 4-9 MORN, 10-16 DAY, 17-19 EVE, 20-23 NITE, with LATE folded into the
-- NITE slot exactly like the animation band map.
local BAND_BY_HOUR = {
  "nite",
  "nite",
  "nite",
  "nite", -- 0-3 (LATE)
  "morn",
  "morn",
  "morn",
  "morn",
  "morn",
  "morn", -- 4-9
  "day",
  "day",
  "day",
  "day",
  "day",
  "day",
  "day", -- 10-16
  "eve",
  "eve",
  "eve", -- 17-19
  "nite",
  "nite",
  "nite",
  "nite", -- 20-23
}

-- The band for an RTC hour (0-23), following GF_RTC_GetTimeOfDayByHour.
---@param hour integer
---@return string
function TimeOfDayProps.bandForHour(hour)
  assert(
    type(hour) == "number" and hour >= 0 and hour < 24 and math.floor(hour) == hour,
    "bandForHour requires an integer hour in 0..23"
  )
  return BAND_BY_HOUR[hour + 1]
end

-- The band for seconds-since-midnight (the engine's field time unit).
---@param seconds integer
---@return string
function TimeOfDayProps.bandForSeconds(seconds)
  assert(type(seconds) == "number" and seconds >= 0, "bandForSeconds requires non-negative seconds")
  return TimeOfDayProps.bandForHour(math.floor(seconds / 3600) % 24)
end

-- The band plan of a model definition: band -> clip for every clip carrying
-- compiled time-band metadata, or nil when the model has no banded clips.
-- Bands are compiled from the banded anim-list record's unique slots, so a
-- duplicate band claim here is a programming error.
---@param definition { key: string, animations: TimeOfDayProps.Clip[] }
---@return { [string]: TimeOfDayProps.Clip }?
function TimeOfDayProps.plan(definition)
  assert(type(definition) == "table" and definition.animations ~= nil, "plan requires a model definition")
  local byBand = {}
  for _, clip in ipairs(definition.animations) do
    local band = clip.timeBand
    if band then
      assert(byBand[band] == nil, "model " .. definition.key .. " claims time band " .. band .. " twice")
      byBand[band] = clip
    end
  end
  if next(byBand) == nil then
    return nil
  end
  return byBand
end

-- Swap a banded instance from one band to another (the decomp's remove-and-
-- add): stop the previous band's clip, play the current band's clip looping
-- from frame 0. `fromBand` is nil at load (nothing playing yet). A band
-- without a clip just stops the previous playback.
---@param instance TimeOfDayProps.Instance
---@param plan { [string]: TimeOfDayProps.Clip }
---@param fromBand string?
---@param toBand string?
function TimeOfDayProps.swap(instance, plan, fromBand, toBand)
  assert(type(instance) == "table" and instance.play ~= nil and instance.stop ~= nil, "swap requires a ModelInstance")
  assert(type(plan) == "table", "swap requires a band plan")
  local from = fromBand and plan[fromBand]
  local to = toBand and plan[toBand]
  if from and from ~= to then
    instance:stop(from.name)
  end
  if to and to ~= from then
    instance:play(to.name, { loopMode = "loop" })
  end
end

return TimeOfDayProps
