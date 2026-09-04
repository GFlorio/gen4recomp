-- Closed source-independent profiles for generated field-object movement.

local FieldObjectMovement = {}

local WAIT_CHOICES = { 16, 32, 48, 64 }

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function randomProfile(kind, directions, nearbyPlayerFacing)
  return {
    kind = kind,
    directions = directions,
    waitChoices = copy(WAIT_CHOICES),
    nearbyPlayerFacing = nearbyPlayerFacing == true,
  }
end

local function pattern(sequence)
  return { kind = "pattern", sequence = sequence }
end

local PROFILES = {
  stationary = { kind = "stationary" },
  player = { kind = "special", special = "player" },
  look_around = randomProfile("look", { "north", "south", "west", "east" }, true),
  wander_around = randomProfile("wander", { "north", "south", "west", "east" }),
  wander_north_south = randomProfile("wander", { "north", "south" }),
  wander_west_east = randomProfile("wander", { "west", "east" }),
  look_north_west = randomProfile("look", { "north", "west" }, true),
  look_north_east = randomProfile("look", { "north", "east" }, true),
  look_south_west = randomProfile("look", { "south", "west" }, true),
  look_south_east = randomProfile("look", { "south", "east" }, true),
  look_north_south_west = randomProfile("look", { "north", "south", "west" }, true),
  look_north_south_east = randomProfile("look", { "north", "south", "east" }, true),
  look_north_west_east = randomProfile("look", { "north", "west", "east" }, true),
  look_south_west_east = randomProfile("look", { "south", "west", "east" }, true),
  look_north = { kind = "stationary", fixedFacing = "north" },
  look_south = { kind = "stationary", fixedFacing = "south" },
  look_west = { kind = "stationary", fixedFacing = "west" },
  look_east = { kind = "stationary", fixedFacing = "east" },
  rotate_counterclockwise = {
    kind = "rotate",
    sequence = { "north", "west", "south", "east" },
    rotationInterval = 24,
    nearbyPlayerFacing = true,
  },
  rotate_clockwise = {
    kind = "rotate",
    sequence = { "north", "east", "south", "west" },
    rotationInterval = 24,
    nearbyPlayerFacing = true,
  },
  walk_back_and_forth = { kind = "shuttle" },
  walk_north_east_west_south = pattern({ "north", "east", "west", "south" }),
  walk_east_west_south_north = pattern({ "east", "west", "south", "north" }),
  walk_south_north_east_west = pattern({ "south", "north", "east", "west" }),
  walk_west_south_north_east = pattern({ "west", "south", "north", "east" }),
  walk_west_east_south_north = pattern({ "west", "east", "south", "north" }),
  walk_north_west_east_south = pattern({ "north", "west", "east", "south" }),
  walk_south_north_west_east = pattern({ "south", "north", "west", "east" }),
  walk_east_south_north_west = pattern({ "east", "south", "north", "west" }),
  walk_west_north_south_east = pattern({ "west", "north", "south", "east" }),
  walk_north_south_east_west = pattern({ "north", "south", "east", "west" }),
  walk_east_west_north_south = pattern({ "east", "west", "north", "south" }),
  walk_south_east_west_north = pattern({ "south", "east", "west", "north" }),
  walk_east_north_south_west = pattern({ "east", "north", "south", "west" }),
  walk_north_south_west_east = pattern({ "north", "south", "west", "east" }),
  walk_west_east_north_south = pattern({ "west", "east", "north", "south" }),
  walk_south_west_east_north = pattern({ "south", "west", "east", "north" }),
  walk_north_west_south_east = pattern({ "north", "west", "south", "east" }),
  walk_south_east_north_west = pattern({ "south", "east", "north", "west" }),
  walk_west_south_east_north = pattern({ "west", "south", "east", "north" }),
  walk_east_north_west_south = pattern({ "east", "north", "west", "south" }),
  walk_north_east_south_west = pattern({ "north", "east", "south", "west" }),
  walk_south_west_north_east = pattern({ "south", "west", "north", "east" }),
  walk_west_north_east_south = pattern({ "west", "north", "east", "south" }),
  walk_east_south_west_north = pattern({ "east", "south", "west", "north" }),
  look_north_south = randomProfile("look", { "north", "south" }, true),
  look_west_east = randomProfile("look", { "west", "east" }, true),
  null_slot = { kind = "special", special = "null" },
  follow_player = { kind = "special", special = "follower" },
  vs_seeker_spin = {
    kind = "spin",
    spinInterval = 24,
    clockwiseSequence = { "north", "east", "south", "west" },
    counterclockwiseSequence = { "north", "west", "south", "east" },
  },
  follow_partner = { kind = "special", special = "partner" },
  disguise_snow = { kind = "special", special = "disguise" },
  disguise_sand = { kind = "special", special = "disguise" },
  disguise_rock = { kind = "special", special = "disguise" },
  disguise_grass = { kind = "special", special = "disguise" },
  follow_transition_a = { kind = "special", special = "follower_transition" },
  follow_transition_b = { kind = "special", special = "follower_transition" },
}

local VALID_DIRECTIONS = { north = true, south = true, west = true, east = true }
local VALID_KINDS = {
  stationary = true,
  look = true,
  wander = true,
  rotate = true,
  shuttle = true,
  pattern = true,
  spin = true,
  special = true,
}

local function assertArray(name, values)
  assert(type(values) == "table", name .. " must be an array")
  assert(#values > 0, name .. " must not be empty")
  local seen = {}
  for _, direction in ipairs(values) do
    assert(VALID_DIRECTIONS[direction], name .. " contains an invalid direction")
    assert(not seen[direction], name .. " contains a duplicate direction")
    seen[direction] = true
  end
end

local function assertWaitChoices(name, values)
  assert(type(values) == "table" and #values == 4, name .. " must contain four waits")
  for index, wait in ipairs(values) do
    assert(wait == WAIT_CHOICES[index], name .. " is not canonical")
  end
end

local profileCount = 0
for name, profile in pairs(PROFILES) do
  profileCount = profileCount + 1
  assert(type(name) == "string" and #name > 0, "movement profile names must be non-empty strings")
  assert(VALID_KINDS[profile.kind], "unknown movement profile kind for " .. name)
  if profile.directions ~= nil then
    assertArray(name .. ".directions", profile.directions)
  end
  if profile.sequence ~= nil then
    assertArray(name .. ".sequence", profile.sequence)
  end
  if profile.kind == "spin" then
    assert(type(profile.spinInterval) == "number" and profile.spinInterval % 1 == 0, name .. ".spinInterval is invalid")
    assertArray(name .. ".clockwiseSequence", profile.clockwiseSequence)
    assert(#profile.clockwiseSequence == 4, name .. ".clockwiseSequence must contain four directions")
    assertArray(name .. ".counterclockwiseSequence", profile.counterclockwiseSequence)
    assert(#profile.counterclockwiseSequence == 4, name .. ".counterclockwiseSequence must contain four directions")
  else
    assert(profile.spinInterval == nil, name .. " has an unexpected spin interval")
    assert(profile.clockwiseSequence == nil, name .. " has an unexpected clockwise sequence")
    assert(profile.counterclockwiseSequence == nil, name .. " has an unexpected counterclockwise sequence")
  end
  if profile.fixedFacing ~= nil then
    assert(VALID_DIRECTIONS[profile.fixedFacing], name .. ".fixedFacing is invalid")
  end
  if profile.waitChoices ~= nil then
    assertWaitChoices(name .. ".waitChoices", profile.waitChoices)
  end
  if profile.nearbyPlayerFacing ~= nil then
    assert(type(profile.nearbyPlayerFacing) == "boolean", name .. ".nearbyPlayerFacing must be boolean")
  end
  if profile.kind == "special" then
    assert(type(profile.special) == "string" and #profile.special > 0, name .. ".special is required")
  else
    assert(profile.special == nil, name .. " has an unexpected special classification")
  end
end
assert(profileCount == 57, "movement profile catalog is incomplete")

---@param typeName string
---@return table<string, unknown>
function FieldObjectMovement.require(typeName)
  local profile = PROFILES[typeName]
  assert(profile ~= nil, "unknown field object movement type " .. tostring(typeName))
  return copy(profile)
end

---@param typeName unknown
---@return boolean
function FieldObjectMovement.isType(typeName)
  return type(typeName) == "string" and PROFILES[typeName] ~= nil
end

return FieldObjectMovement
