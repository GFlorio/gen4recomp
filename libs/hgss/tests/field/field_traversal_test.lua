-- FieldTraversal tests anchor normalized behavior categories and semantic
-- decisions without terrain, actors, progression, or host dependencies.

local Assert = require("tests.support.Assert")
local FieldTraversal = require("libs.hgss.src.world.FieldTraversal")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

local T = {}
local BEHAVIOR = MetatileBehavior.BEHAVIOR

function T.metatile_behavior_names_cover_navigation_categories()
  Assert.isTrue(MetatileBehavior.isTallGrass(BEHAVIOR.TALL_GRASS))
  Assert.isTrue(MetatileBehavior.isVeryTallGrass(BEHAVIOR.VERY_TALL_GRASS))
  Assert.isTrue(MetatileBehavior.isSurfableWater(BEHAVIOR.RIVER_WATER))
  Assert.isTrue(MetatileBehavior.isSurfableWater(BEHAVIOR.SEA_WATER))
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.WATERFALL), "waterfall")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.WHIRLPOOL), "whirlpool")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.ROCK_CLIMB_EAST_WEST), "rock_climb")
  Assert.equal(MetatileBehavior.fieldAction(BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH), "rock_climb")
  Assert.isFalse(MetatileBehavior.isSurfableWater(BEHAVIOR.TALL_GRASS))
end

function T.source_behavior_values_and_directions_are_exact()
  local ledges = {
    { name = "JUMP_EAST", value = 56, direction = "east" },
    { name = "JUMP_WEST", value = 57, direction = "west" },
    { name = "JUMP_NORTH", value = 58, direction = "north" },
    { name = "JUMP_SOUTH", value = 59, direction = "south" },
  }
  for _, expected in ipairs(ledges) do
    Assert.equal(BEHAVIOR[expected.name], expected.value)
    Assert.equal(MetatileBehavior.ledgeDirection(expected.value), expected.direction)
  end
  Assert.equal(BEHAVIOR.ROCK_CLIMB_NORTH_SOUTH, 75)
  Assert.equal(BEHAVIOR.ROCK_CLIMB_EAST_WEST, 76)
  Assert.equal(MetatileBehavior.fieldAction(75), "rock_climb")
  Assert.equal(MetatileBehavior.fieldAction(76), "rock_climb")
end

function T.ledge_traversal_requires_the_source_direction()
  local ledges = {
    { behavior = 56, direction = "east" },
    { behavior = 57, direction = "west" },
    { behavior = 58, direction = "north" },
    { behavior = 59, direction = "south" },
  }
  for _, ledge in ipairs(ledges) do
    local matching = FieldTraversal.classify({ behavior = ledge.behavior, blocked = true }, ledge.direction)
    Assert.equal(matching.kind, "ledge_jump")
    local wrongDirection = ledge.direction == "east" and "north" or "east"
    local wrong = FieldTraversal.classify({ behavior = ledge.behavior, blocked = true }, wrongDirection)
    Assert.equal(wrong.kind, "blocked")
  end
end

function T.field_actions_are_semantic_even_when_permission_is_blocked()
  for _, behavior in ipairs({ BEHAVIOR.RIVER_WATER, BEHAVIOR.WATERFALL, BEHAVIOR.WHIRLPOOL }) do
    local decision = FieldTraversal.classify({ behavior = behavior, blocked = true }, "east")
    Assert.equal(decision.kind, "field_action")
  end
end

function T.ledge_direction_controls_the_traversal_kind()
  local matching = FieldTraversal.classify({ behavior = BEHAVIOR.JUMP_EAST, blocked = true }, "east")
  Assert.equal(matching.kind, "ledge_jump")
  local wrong = FieldTraversal.classify({ behavior = BEHAVIOR.JUMP_EAST, blocked = false }, "north")
  Assert.equal(wrong.kind, "blocked")
  local ordinary = FieldTraversal.classify({ behavior = 0, blocked = false }, "east")
  Assert.equal(ordinary.kind, "step")
end

return { tests = T }
