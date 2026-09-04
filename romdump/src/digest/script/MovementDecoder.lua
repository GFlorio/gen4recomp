-- Movement instruction decoder : maps the HGSS movement
-- codes to DSL movement actions. Codes without a stable semantic name emit
-- explicit unsupported movement actions; an ApplyMovement containing one
-- makes the generated script incomplete. The direction base is the code
-- modulo 4 (north/south/west/east) and the action family is the code range.
-- Pure domain module: no love dependency.

local MovementDecoder = {}

local DIRECTIONS = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }

local function decodeFace(code, count)
  return { action = "face", direction = DIRECTIONS[code % 4], count = count }
end

-- The supported family table: range -> function(code, count) -> step.
local FAMILIES = {
  {
    first = 0,
    last = 3,
    fn = decodeFace,
  },
  { first = 4, last = 7, speed = "slower" },
  { first = 8, last = 11, speed = "slow" },
  { first = 12, last = 15, speed = "normal" },
  { first = 16, last = 19, speed = "fast" },
  { first = 20, last = 23, speed = "faster" },
  { first = 24, last = 27, inPlace = "slower" },
  { first = 28, last = 31, inPlace = "slow" },
  { first = 32, last = 35, inPlace = "normal" },
  { first = 36, last = 39, inPlace = "fast" },
  { first = 40, last = 43, inPlace = "faster" },
  { first = 44, last = 47, jump = { distance = "zero", speed = "slow" } },
  { first = 48, last = 51, jump = { distance = "zero", speed = "fast" } },
  { first = 52, last = 55, jump = { distance = "near", speed = "fast" } },
  { first = 56, last = 59, jump = { distance = "far", speed = "fast" } },
  { first = 60, last = 66, delayTicks = { 1, 2, 4, 8, 15, 16, 32 } },
  { first = 76, last = 79, speed = "slightly_fast" },
  { first = 80, last = 83, speed = "slightly_faster" },
  { first = 88, last = 91, speed = "run" },
}

local SINGLES = {
  [67] = { action = "gesture", name = "warp_out" },
  [68] = { action = "gesture", name = "warp_in" },
  [69] = { action = "set_visible", visible = false },
  [70] = { action = "set_visible", visible = true },
  [71] = { action = "lock_facing" },
  [72] = { action = "unlock_facing" },
  [73] = { action = "pause_animation" },
  [74] = { action = "resume_animation" },
  [75] = { action = "emote", name = "exclamation" },
  [100] = { action = "gesture", name = "nurse_bow" },
  [101] = { action = "reveal_trainer" },
  [102] = { action = "gesture", name = "give" },
  [103] = { action = "emote", name = "question" },
  [104] = { action = "gesture", name = "receive" },
  [153] = { action = "emote", name = "exclamation_alt" },
}

local TRAJECTORIES = {
  [105] = {
    { deltaX = 0, surfaceBandDelta = 1, deltaZ = 5, direction = "south", ticks = 15 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -5, direction = "north", ticks = 15 },
    { deltaX = -2, surfaceBandDelta = 0, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 1, deltaZ = -4, direction = "west", ticks = 12 },
  },
  [106] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 0, direction = "east", ticks = 6 },
    { deltaX = -1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 6 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
  },
  [107] = {
    { deltaX = 3, surfaceBandDelta = 1, deltaZ = -1, direction = "east", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = -1, deltaZ = -4, direction = "north", ticks = 6 },
    { deltaX = 1, surfaceBandDelta = 1, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 12 },
  },
  [109] = {
    { deltaX = 3, surfaceBandDelta = 1, deltaZ = -1, direction = "east", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = -1, deltaZ = -4, direction = "north", ticks = 6 },
    { deltaX = 1, surfaceBandDelta = 1, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [108] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 5, direction = "south", ticks = 9 },
    { deltaX = 1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [110] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = 1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [111] = {
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = 2, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 6 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -2, direction = "north", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 1, direction = "south", ticks = 9 },
  },
  [112] = {
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
  },
}

-- Decode one movement action. Returns an ordered list of DSL action tables, or
-- nil plus the unsupported descriptor. Simple commands return a one-element list.
-- Trajectory commands 105-112 expand to their full semantic segment list, with
-- count repetitions cloned as independent ordered entries.
---@param action table<string, unknown>
---@return table[]|nil steps, table<string, unknown>|nil unsupported
function MovementDecoder.decode(action)
  local code = action.movementCode or -1
  local count = action.count or 1
  local trajectory = TRAJECTORIES[code]
  if trajectory ~= nil then
    assert(type(count) == "number" and count % 1 == 0 and count > 0, "trajectory count must be a positive integer")
    local result = {}
    for _ = 1, count do
      for _, segment in ipairs(trajectory) do
        result[#result + 1] = {
          action = "trajectory_segment",
          deltaX = segment.deltaX,
          surfaceBandDelta = segment.surfaceBandDelta,
          deltaZ = segment.deltaZ,
          direction = segment.direction,
          ticks = segment.ticks,
        }
      end
    end
    return result, nil
  end
  local single = SINGLES[code]
  if single ~= nil then
    local step = {}
    for key, value in pairs(single) do
      step[key] = value
    end
    if step.action == "emote" or step.action == "gesture" then
      step.count = count
    end
    return { step }, nil
  end
  if code == 94 or code == 95 then
    local direction = DIRECTIONS[code % 4]
    return {
      {
        action = "jump",
        direction = direction,
        distance = "farther",
        speed = "fast",
        count = count,
      },
    },
      nil
  end
  for _, family in ipairs(FAMILIES) do
    if code >= family.first and code <= family.last then
      local direction = DIRECTIONS[code % 4]
      if family.fn ~= nil then
        return { family.fn(code, count) }, nil
      end
      if family.delayTicks ~= nil then
        return { { action = "delay", ticks = family.delayTicks[code - family.first + 1], count = count } }, nil
      end
      if family.jump ~= nil then
        return {
          {
            action = "jump",
            direction = direction,
            distance = family.jump.distance,
            speed = family.jump.speed,
            count = count,
          },
        },
          nil
      end
      if family.inPlace ~= nil then
        return {
          {
            action = "walk_in_place",
            direction = direction,
            speed = family.inPlace,
            count = count,
          },
        },
          nil
      end
      return {
        {
          action = "walk",
          direction = direction,
          speed = family.speed,
          tiles = count,
        },
      },
        nil
    end
  end
  return nil,
    {
      code = code,
      count = count,
      originalName = action.name,
      reason = "movement code outside the supported matrix",
    }
end

return MovementDecoder
