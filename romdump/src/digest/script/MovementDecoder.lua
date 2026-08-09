-- Movement instruction decoder : maps the HGSS movement
-- codes to DSL movement actions. Codes without a stable semantic name emit
-- explicit unsupported movement actions; an ApplyMovement containing one
-- makes the generated script incomplete. The direction base is the code
-- modulo 4 (north/south/west/east) and the action family is the code range.
-- Pure domain module: no love dependency.

local MovementDecoder = {}

local DIRECTIONS = { [0] = "north", [1] = "south", [2] = "west", [3] = "east" }

-- The supported family table: range -> function(code, count) -> step.
local FAMILIES = {
  {
    first = 0,
    last = 3,
    fn = function(code, count)
      return { action = "face", direction = DIRECTIONS[code % 4], count = count }
    end,
  },
  { first = 8, last = 11, speed = "slow" },
  { first = 12, last = 15, speed = "normal" },
  { first = 16, last = 19, speed = "fast" },
  { first = 24, last = 27, inPlace = "slower" },
  { first = 28, last = 31, inPlace = "slow" },
  { first = 32, last = 35, inPlace = "normal" },
  { first = 36, last = 39, inPlace = "fast" },
  { first = 44, last = 47, jump = { distance = "zero", speed = "slow" } },
  { first = 48, last = 51, jump = { distance = "zero", speed = "fast" } },
  { first = 52, last = 55, jump = { distance = "near", speed = "fast" } },
  { first = 56, last = 59, jump = { distance = "far", speed = "fast" } },
  { first = 60, last = 66, delayTicks = { 1, 2, 4, 8, 15, 16, 32 } },
  { first = 76, last = 79, speed = "slightly_fast" },
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
  [102] = { action = "gesture", name = "give" },
  [103] = { action = "emote", name = "question" },
  [104] = { action = "gesture", name = "receive" },
  [153] = { action = "emote", name = "exclamation_alt" },
}

-- Decode one movement action. Returns the DSL action table, or nil plus the
-- unsupported descriptor .
---@param action table
---@return table|nil step, table|nil unsupported
function MovementDecoder.decode(action)
  local code = action.movementCode or -1
  local count = action.count or 1
  local single = SINGLES[code]
  if single ~= nil then
    local step = {}
    for key, value in pairs(single) do
      step[key] = value
    end
    if step.action == "emote" or step.action == "gesture" then
      step.count = count
    end
    return step, nil
  end
  for _, family in ipairs(FAMILIES) do
    if code >= family.first and code <= family.last then
      local direction = DIRECTIONS[code % 4]
      if family.fn ~= nil then
        return family.fn(code, count), nil
      end
      if family.delayTicks ~= nil then
        return { action = "delay", ticks = family.delayTicks[code - family.first + 1], count = count }, nil
      end
      if family.jump ~= nil then
        return {
          action = "jump",
          direction = direction,
          distance = family.jump.distance,
          speed = family.jump.speed,
          count = count,
        },
          nil
      end
      if family.inPlace ~= nil then
        return {
          action = "walk_in_place",
          direction = direction,
          speed = family.inPlace,
          count = count,
        },
          nil
      end
      return {
        action = "walk",
        direction = direction,
        speed = family.speed,
        tiles = count,
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
