-- The single compiled texture-SRT (NSBTA) clip contract shared by the
-- model descriptor gate and the map scene cache: a clip whose kind is
-- texsrt carries one compiled target per track, every target carries all
-- five texture-SRT channels, and the curve payloads are exactly what the
-- CompiledNsbtaSampler consumes (rate 1/2/4, limit == frameCount, and
-- enough integer keys for every frame the sampler can reach, including
-- the rate-2/rate-4 interpolation lookahead). Track target names are the
-- runtime binding keys, so they must resolve onto the compiled targets
-- and be unique. The owning descriptor validator supplies `invalid(reason)`
-- so ModelAsset and MapAssetCache raise their own owner-local error codes at
-- their boundaries. Pure domain module.

local AnimationClip = require("libs.assets.src.AnimationClip")
local Validate = require("libs.assets.src.Validate")

local CompiledNsbtaClip = {}

---@class CompiledNsbtaClip
---@field validate fun(clip: table, invalid: fun(reason: string))

local CURVE_RATES = { [1] = true, [2] = true, [4] = true }
local STORAGES = { fx16 = true, fx32 = true }

-- The five texture-SRT channels every compiled target carries.
local CHANNELS = { "transS", "transT", "rot", "scaleS", "scaleT" }

-- A finite integer (rejects fractional, NaN, and infinite values).
---@param value number
---@return boolean
local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

-- The number of keys the sampler can reach for a curve of `rate` over
-- `frameCount` frames: frames 0..frameCount-1 index keys[floor(frame/rate)]
-- and the rate-2/rate-4 interpolations read one key ahead, so the last
-- reachable key index is floor((frameCount - 1) / rate) + 1 for the
-- interpolating frames and floor((frameCount - 1) / rate) for exact
-- multiples.
---@param rate integer
---@param frameCount integer
---@return integer
local function requiredKeys(rate, frameCount)
  local lastFrame = frameCount - 1
  if rate == 2 then
    return math.floor(frameCount / 2) + 1
  elseif rate == 4 then
    local anchor = math.floor(lastFrame / 4)
    return anchor + 1 + (lastFrame % 4 == 0 and 0 or 1)
  end
  return frameCount
end

-- One compiled channel: a constant integer or a curve with a Nitro rate,
-- limit == frameCount, an fx16/fx32 storage, and integer keys covering
-- every reachable frame.
---@param channel table
---@param where string
---@param clip table
---@param invalid fun(reason: string)
local function checkChannel(channel, where, clip, invalid)
  if type(channel) ~= "table" then
    invalid(where .. " is missing")
    return
  end
  if channel.source == "constant" then
    if not isInteger(channel.value) then
      invalid(where .. " constant value must be an integer")
    end
  elseif channel.source == "curve" then
    if not CURVE_RATES[channel.rate] then
      invalid(where .. " curve rate must be 1, 2, or 4")
    end
    if channel.limit ~= clip.frameCount then
      invalid(where .. " curve limit must equal the clip frameCount")
    end
    if not STORAGES[channel.storage] then
      invalid(where .. " curve storage must be fx16 or fx32")
    end
    if Validate.isArray(channel.keys) then
      local keys = channel.keys ---@type number[]
      if #keys < requiredKeys(channel.rate, clip.frameCount) then
        invalid(where .. " curve carries fewer keys than its frames demand")
      end
      for i, key in ipairs(keys) do
        if type(key) ~= "number" or not isInteger(key) then
          invalid(where .. " curve key " .. i .. " must be an integer")
        end
      end
    else
      invalid(where .. " curve requires a keys array")
    end
  else
    invalid(where .. " channel source must be constant or curve")
  end
end

-- Validate the full compiled clip contract. Raises nothing itself: every
-- violation calls `invalid(reason)`, supplied by the owning descriptor
-- validator so the error reports under the owner's code.
---@param clip table the compiled texture-SRT clip record
---@param invalid fun(reason: string) the owning validator's failure sink
function CompiledNsbtaClip.validate(clip, invalid)
  local where = "clip " .. tostring(clip and clip.id) .. " " ---@type string
  if
    type(clip) ~= "table"
    or type(clip.id) ~= "string"
    or #clip.id == 0
    or type(clip.name) ~= "string"
    or #clip.name == 0
    or clip.category ~= AnimationClip.CATEGORIES.material
    or clip.kind ~= AnimationClip.KINDS.TEXSRT
    or not (isInteger(clip.frameCount) and clip.frameCount >= 1)
    or not Validate.isArray(clip.tracks)
    or not Validate.isArray(clip.semanticNames)
  then
    invalid(
      "clip must carry a non-empty id and name, category material, kind texsrt, a positive frameCount, tracks, and semanticNames"
    )
    return
  end
  if type(clip.compiled) ~= "table" or not Validate.isArray(clip.compiled.targets) or #clip.compiled.targets == 0 then
    invalid(where .. "compiled.targets must be a non-empty array")
    return
  end

  local targets = clip.compiled.targets ---@type table[]
  local tracks = clip.tracks ---@type table[]
  if #tracks ~= #targets then
    invalid(where .. "must carry one track per compiled target")
    return
  end

  -- Track target names are the runtime binding keys, so each track must
  -- resolve onto its selected compiled target and the names must be unique.
  local seenTargetNames = {} ---@type table<string, boolean>
  for i, track in ipairs(tracks) do
    local whereTrack = where .. "track " .. i .. " "
    if type(track) ~= "table" or type(track.target) ~= "string" or #track.target == 0 then
      invalid(whereTrack .. "requires a non-empty string target")
      return
    end
    if not (isInteger(track.targetIndex) and track.targetIndex >= 0 and targets[track.targetIndex + 1]) then
      invalid(whereTrack .. "targetIndex must be a zero-based integer inside compiled.targets")
      return
    end
    local selected = targets[track.targetIndex + 1] ---@type table
    if type(selected) ~= "table" or selected.name ~= track.target then
      invalid(whereTrack .. "target must name the compiled target it selects")
      return
    end
    if seenTargetNames[track.target] then
      invalid(whereTrack .. "duplicate track target " .. track.target)
    end
    seenTargetNames[track.target] = true
  end

  for i, target in ipairs(targets) do
    local whereTarget = where .. "target " .. i .. " " ---@type string
    if
      type(target) ~= "table"
      or type(target.name) ~= "string"
      or not (isInteger(target.index) and target.index >= 0)
    then
      invalid(whereTarget .. "requires a name and a non-negative integer index")
      return
    end
    local channels = target.channels ---@type table
    if type(channels) ~= "table" then
      invalid(whereTarget .. "requires a channels table")
      return
    end
    for _, name in ipairs(CHANNELS) do
      checkChannel(channels[name], whereTarget .. "channel " .. name, clip, invalid)
    end
  end
end

return CompiledNsbtaClip
