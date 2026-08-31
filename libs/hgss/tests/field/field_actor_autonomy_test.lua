-- FieldActorAutonomy tests cover semantic controller timing without field I/O.

local Assert = require("tests.support.Assert")
local FieldActorAutonomy = require("libs.hgss.src.field.FieldActorAutonomy")

local T = {}

local function rng(values)
  local index = 0
  return {
    nextInt = function(_, maximum)
      index = index + 1
      local value = values[index] or 0
      Assert.isTrue(value >= 0 and value < maximum, "deterministic roll must fit its bound")
      return value
    end,
  }
end

local function actorEvent(movementType, overrides)
  local event = {
    x = 4,
    z = 5,
    y = 0,
    facingDirection = "south",
    movementType = movementType,
    type = 0,
    param0 = 0,
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function capability(overrides)
  local calls = { facing = {}, walks = {} }
  local result = {
    fieldX = 4,
    fieldZ = 5,
    surfaceId = 1,
    worldY = 0,
    setFacing = function(_, actorId, direction)
      calls.facing[#calls.facing + 1] = { actorId = actorId, direction = direction }
    end,
    walk = function(_, actorId, direction)
      calls.walks[#calls.walks + 1] = { actorId = actorId, direction = direction }
      return true
    end,
  }
  for key, value in pairs(overrides or {}) do
    rawset(result, key, value)
  end
  result.calls = calls
  return result
end

function T.random_profiles_use_profile_directions_and_source_waits()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 3 }) })
  autonomy:attach("actor", "look_north_west", actorEvent("look_north_west"))
  local look = capability()
  autonomy:step("actor", look)
  Assert.equal(look.calls.facing[1].direction, "north")
  Assert.equal(autonomy:state("actor").timer, 64)

  autonomy = FieldActorAutonomy.new({ rng = rng({ 1, 0 }) })
  autonomy:attach("walker", "wander_west_east", actorEvent("wander_west_east"))
  local walk = capability()
  autonomy:step("walker", walk)
  Assert.equal(walk.calls.facing[1].direction, "east")
  Assert.equal(walk.calls.walks[1].direction, "east")
  Assert.equal(autonomy:state("walker").timer, 16)
end

function T.fixed_rotation_and_spin_profiles_do_not_translate()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 0 }) })
  autonomy:attach("fixed", "look_west", actorEvent("look_west"))
  local fixed = capability()
  autonomy:step("fixed", fixed)
  Assert.equal(fixed.calls.facing[1].direction, "west")
  Assert.equal(#fixed.calls.walks, 0)

  autonomy:attach("spin", "vs_seeker_spin", actorEvent("vs_seeker_spin"))
  local spin = capability()
  autonomy:step("spin", spin)
  Assert.equal(spin.calls.facing[1].direction, "east")
  Assert.equal(#spin.calls.walks, 0)
  for _ = 1, 3 do
    autonomy:step("spin", spin)
  end
  Assert.equal(#spin.calls.facing, 1)
  autonomy:step("spin", spin)
  Assert.equal(spin.calls.facing[2].direction, "south")
end

function T.rotation_and_sequence_profiles_preserve_order_and_retry_once()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0 }) })
  autonomy:attach("rotate", "rotate_clockwise", actorEvent("rotate_clockwise"))
  local rotate = capability()
  autonomy:step("rotate", rotate)
  Assert.equal(rotate.calls.facing[1].direction, "west")
  Assert.equal(autonomy:state("rotate").timer, 24)

  autonomy:attach(
    "pattern",
    "walk_north_east_west_south",
    actorEvent("walk_north_east_west_south", { facingDirection = "north" })
  )
  local attempts = 0
  local pattern
  pattern = capability({
    walk = function(_, actorId, direction)
      attempts = attempts + 1
      pattern.calls.walks[#pattern.calls.walks + 1] = { actorId = actorId, direction = direction }
      return attempts > 1 and direction == "east"
    end,
  })
  autonomy:step("pattern", pattern)
  Assert.equal(attempts, 2)
  Assert.equal(pattern.calls.walks[1].direction, "north")
  Assert.equal(pattern.calls.walks[2].direction, "east")
  Assert.equal(autonomy:state("pattern").sequenceIndex, 3)

  autonomy:attach("shuttle", "walk_back_and_forth", actorEvent("walk_back_and_forth"))
  local shuttle
  shuttle = capability({
    walk = function(_, actorId, direction)
      shuttle.calls.walks[#shuttle.calls.walks + 1] = { actorId = actorId, direction = direction }
      return false
    end,
  })
  autonomy:step("shuttle", shuttle)
  Assert.equal(shuttle.calls.walks[1].direction, "south")
  Assert.equal(shuttle.calls.walks[2].direction, "north")
end

function T.nearby_player_facing_requires_source_gates_and_allowed_direction()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 0 }) })
  autonomy:attach("actor", "look_north_south", actorEvent("look_north_south", { type = 1, param0 = 2 }))
  local near = capability({ player = { fieldX = 4, fieldZ = 4, surfaceId = 1, worldY = 0 } })
  autonomy:step("actor", near)
  Assert.equal(near.calls.facing[1].direction, "north")

  local far = capability({ player = { fieldX = 4, fieldZ = 8, surfaceId = 1, worldY = 0 } })
  autonomy:setMovementType("actor", "look_north_south")
  autonomy:step("actor", far)
  Assert.equal(far.calls.facing[1].direction, "north")

  local wrongSurface = capability({ player = { fieldX = 4, fieldZ = 4, surfaceId = 2, worldY = 0 } })
  autonomy:setMovementType("actor", "look_north_south")
  autonomy:step("actor", wrongSurface)
  Assert.equal(wrongSurface.calls.facing[1].direction, "north")
end

function T.special_profiles_suspend_and_type_changes_reset_or_defer_state()
  local autonomy = FieldActorAutonomy.new({ rng = rng({ 0, 0 }) })
  autonomy:attach("actor", "follow_player", actorEvent("follow_player"))
  local special = capability()
  autonomy:step("actor", special)
  Assert.equal(#special.calls.facing, 0)
  Assert.equal(#special.calls.walks, 0)

  autonomy:setMovementType("actor", "look_east")
  local fixed = capability()
  autonomy:step("actor", fixed)
  Assert.equal(fixed.calls.facing[1].direction, "east")

  autonomy:setMovementType("actor", "wander_north_south", true)
  Assert.equal(autonomy:state("actor").movementType, "look_east")
  autonomy:applyPendingMovementType("actor")
  Assert.equal(autonomy:state("actor").movementType, "wander_north_south")
  autonomy:detach("actor")
  Assert.throws(function()
    autonomy:state("actor")
  end)
end

return { tests = T }
