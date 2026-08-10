-- TimeOfDayProps: the time-of-day field-prop policy (spec section 39). HGSS
-- registers up to four banded animations per field object -- morning, day,
-- evening, night -- and swaps the active band when the RTC time-of-day
-- changes (pokeheartgold src/field/overlay_01_02204004.c ov01_022047DC, with
-- the band map ov01_022095EC: MORN=0, DAY=1, EVE=2, NITE=3, LATE=3, and the
-- hour table sTimeOfDayByHour in src/gf_rtc.c GF_RTC_GetTimeOfDayByHour).
--
-- A model is banded when its clips declare distinct bands by name suffix
-- (_m/_d/_e/_n, the corpus convention: kk_sky_m/d/e/n, si_light_m1/m2/...);
-- clips that share a band make the model ambiguous and it stays unbanded --
-- the caller decides the band order in HGSS (AreaDataManager_Load, asm
-- only), so the engine never guesses it from slot order. The swap mirrors
-- the decomp's remove-and-add: stop the previous band's clip, play the
-- current band's clip looping. Every other model keeps the ordinary ambient
-- policy. Pure domain module.

local TimeOfDayProps = {}

-- The four bands in HGSS band-slot order (ov01_022095EC indices 0-3; LATE
-- maps to the NITE slot).
TimeOfDayProps.BANDS = { "morn", "day", "eve", "nite" }

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

-- The band suffix of a clip name: a trailing _m/_d/_e/_n (optionally with a
-- variant number, e.g. si_light_m1), or nil.
local BAND_SUFFIX = { m = "morn", d = "day", e = "eve", n = "nite" }

local function bandOf(name)
  local suffix = name:match("_(%a)%d*$")
  return suffix and BAND_SUFFIX[suffix] or nil
end

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

-- The four bands in band order.
---@return string[]
function TimeOfDayProps.bands()
  local out = {}
  for i, band in ipairs(TimeOfDayProps.BANDS) do
    out[i] = band
  end
  return out
end

-- The band plan of a model definition: band -> clip when the model's clips
-- declare at least two distinct bands by name suffix, else nil (not banded).
-- Clips claiming the same band make the model ambiguous and therefore
-- unbanded.
---@param definition { animations: table }
---@return { [string]: table }?
function TimeOfDayProps.plan(definition)
  assert(type(definition) == "table" and definition.animations ~= nil, "plan requires a model definition")
  local byBand = {}
  for _, clip in ipairs(definition.animations) do
    local band = bandOf(clip.name)
    if band then
      if byBand[band] then
        return nil
      end
      byBand[band] = clip
    end
  end
  local count = 0
  for _ in pairs(byBand) do
    count = count + 1
  end
  if count < 2 then
    return nil
  end
  return byBand
end

-- Swap a banded instance from one band to another (the decomp's remove-and-
-- add): stop the previous band's clip, play the current band's clip looping
-- from frame 0. `fromBand` is nil at load (nothing playing yet). A band
-- without a clip just stops the previous playback.
---@param instance ModelInstance
---@param plan { [string]: table }
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
