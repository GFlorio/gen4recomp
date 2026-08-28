-- CompiledNsbtaClip: the one compiled texture-SRT clip contract the model
-- descriptor gate and the map scene cache both enforce. The boundaries are
-- the ones the samplers rely on: full five-channel presence per target,
-- exact curve key coverage for every rate, limit == frameCount, integer
-- key values, and track targets that resolve unambiguously onto compiled
-- targets (TerrainMaterialAnimator binds materials by target name).

local Assert = require("tests.support.Assert")
local AnimationClip = require("libs.assets.src.AnimationClip")
local CompiledNsbtaClip = require("libs.assets.src.CompiledNsbtaClip")

local T = {}

---@class CompiledNsbtaTest.Channel
---@field source string
---@field value number?
---@field rate number?
---@field limit number?
---@field storage string?
---@field keys number[]?

---@class CompiledNsbtaTest.Channels
---@field [string] CompiledNsbtaTest.Channel|nil

---@class CompiledNsbtaTest.Target
---@field index integer
---@field name string
---@field channels CompiledNsbtaTest.Channels

---@class CompiledNsbtaTest.Track
---@field target string
---@field targetIndex integer

---@class CompiledNsbtaTest.Clip
---@field id string
---@field name string
---@field category string
---@field kind string
---@field frameCount integer
---@field tracks CompiledNsbtaTest.Track[]
---@field compiled { targets: CompiledNsbtaTest.Target[] }

---@param value number
---@return table
local function constant(value)
  local channel = { source = "constant", value = value } ---@cast channel CompiledNsbtaTest.Channel
  return channel
end

---@param rate number
---@param keys table
---@param limit number?
---@param storage string?
---@return table
local function curve(rate, keys, limit, storage)
  local channel = {
    source = "curve",
    rate = rate,
    limit = limit or 8,
    storage = storage or "fx16",
    keys = keys,
  } ---@cast channel CompiledNsbtaTest.Channel
  return channel
end

-- A complete five-channel table; named overrides replace individual
-- channels so each malformed case shares the same otherwise-valid base.
---@param overrides table<string, CompiledNsbtaTest.Channel>?
---@return CompiledNsbtaTest.Channels
local function channels(overrides)
  local ch = {
    transS = constant(0),
    transT = constant(0),
    rot = constant(0x10000000),
    scaleS = constant(0x1000),
    scaleT = constant(0x1000),
  } ---@cast ch CompiledNsbtaTest.Channels
  for name, channel in pairs(overrides or {}) do
    ch[name] = channel
  end
  return ch
end

---@param name string
---@param index integer
---@param ch CompiledNsbtaTest.Channels?
---@return CompiledNsbtaTest.Target
local function target(name, index, ch)
  local value = { index = index, name = name, channels = ch or channels() } ---@cast value CompiledNsbtaTest.Target
  return value
end

-- A valid clip: two tracks, two compiled targets, constants only.
---@param mutate fun(clip: CompiledNsbtaTest.Clip)?
---@return CompiledNsbtaTest.Clip
local function clip(mutate)
  local c = {
    id = "area00_ani",
    name = "area00_ani",
    category = AnimationClip.CATEGORIES.material,
    kind = AnimationClip.KINDS.TEXSRT,
    frameCount = 8,
    tracks = {
      { target = "pond_on", targetIndex = 0 },
      { target = "sea_un", targetIndex = 1 },
    },
    semanticNames = {},
    compiled = {
      targets = {
        target("pond_on", 0),
        target("sea_un", 1),
      },
    },
  } ---@cast c CompiledNsbtaTest.Clip
  if mutate then
    mutate(c)
  end
  return c
end

-- The invalid(reason) callback contract the owning descriptor validators
-- supply; the callback records the reason instead of raising.
---@param c table
---@return string?
local function validationError(c)
  local reason = nil
  CompiledNsbtaClip.validate(c, function(r)
    reason = r
  end)
  return reason
end

---@param c CompiledNsbtaTest.Clip
local function assertValid(c)
  Assert.isNil(validationError(c), "expected the clip to validate")
end

---@param c CompiledNsbtaTest.Clip
local function assertInvalid(c)
  Assert.notNil(validationError(c), "expected the clip to fail validation")
end

-- ---- curve key coverage (the sampler indexes keys[floor(frame/rate)] and
-- the rate-2/rate-4 interpolations read one key ahead, so the required
-- count is the highest accessed key index plus one) ----

function T.rate_1_requires_one_key_per_frame()
  assertValid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(1, { 0, 1, 2, 3, 4, 5, 6, 7 }))
  end))
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(1, { 0, 1, 2, 3, 4, 5, 6 }))
  end))
end

function T.rate_2_requires_floor_frame_count_over_2_plus_1_keys()
  assertValid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(2, { 0, 1, 2, 3, 4 }))
  end))
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(2, { 0, 1, 2, 3 }))
  end))
end

function T.rate_4_requires_anchor_keys_for_the_last_frame()
  assertValid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(4, { 0, 1, 2 }))
  end))
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(4, { 0, 1 }))
  end))
end

-- ---- curve limits, sources, and keys ----

function T.curve_limit_must_equal_the_frame_count()
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(1, { 0, 1, 2, 3, 4, 5, 6, 7 }, 6))
  end))
end

function T.unsupported_channel_sources_are_rejected()
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", { source = "linear", value = 0 })
  end))
end

function T.unsupported_curve_rates_and_storages_are_rejected()
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(0, { 0 }))
  end))
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(1, { 0 }, 8, "fx8"))
  end))
end

function T.curve_keys_must_be_integers()
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", curve(1, { 0, 0.5 }))
  end))
end

function T.constant_values_must_be_integers()
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1].channels, "transS", constant(1.5))
  end))
end

-- ---- missing channels ----

function T.missing_channels_are_rejected()
  for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
    assertInvalid(clip(function(c)
      rawset(c.compiled.targets[1].channels, name, nil)
    end))
  end
  assertInvalid(clip(function(c)
    rawset(c.compiled.targets[1], "channels", nil)
  end))
end

-- ---- tracks vs compiled targets ----

function T.duplicate_track_target_names_are_rejected()
  -- Both tracks agree with their selected compiled targets, so only the
  -- duplicate binding key (TerrainMaterialAnimator binds by target name)
  -- can fail the clip.
  assertInvalid(clip(function(c)
    c.compiled.targets[2].name = "pond_on"
    c.tracks = {
      { target = "pond_on", targetIndex = 0 },
      { target = "pond_on", targetIndex = 1 },
    }
  end))
end

function T.track_target_index_outside_compiled_targets_is_rejected()
  assertInvalid(clip(function(c)
    c.tracks[2].targetIndex = 5
  end))
end

function T.track_target_must_agree_with_the_selected_compiled_target()
  assertInvalid(clip(function(c)
    c.tracks[1].target = "wrong_name"
  end))
end

function T.track_count_must_equal_target_count()
  assertInvalid(clip(function(c)
    c.tracks = { { target = "pond_on", targetIndex = 0 } }
  end))
end

-- ---- clip envelope ----

function T.the_clip_envelope_is_checked()
  assertInvalid(clip(function(c)
    c.id = ""
  end))
  assertInvalid(clip(function(c)
    rawset(c, "name", 5)
  end))
  assertInvalid(clip(function(c)
    c.category = AnimationClip.CATEGORIES.joint
  end))
  assertInvalid(clip(function(c)
    c.kind = AnimationClip.KINDS.TRS
  end))
  assertInvalid(clip(function(c)
    c.frameCount = 0
  end))
  assertInvalid(clip(function(c)
    rawset(c, "frameCount", 2.5)
  end))
  assertInvalid(clip(function(c)
    rawset(c, "tracks", "tracks")
  end))
  assertInvalid(clip(function(c)
    rawset(c, "semanticNames", "names")
  end))
  assertInvalid(clip(function(c)
    rawset(c, "compiled", {})
  end))
  assertInvalid(clip(function(c)
    c.compiled.targets = {}
  end))
  assertInvalid(clip(function(c)
    rawset(c.compiled, "targets", { target("pond_on", 0), 5 })
  end))
end

return { tests = T }
