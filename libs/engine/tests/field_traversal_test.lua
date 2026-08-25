-- FieldTraversal tests anchor normalized behavior categories and semantic
-- decisions without terrain, actors, progression, or host dependencies.

local Assert = require("tests.support.Assert")
local FieldTraversal = require("libs.engine.src.FieldTraversal")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

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

function T.ledge_behavior_names_cover_all_directions()
  Assert.equal(MetatileBehavior.ledgeDirection(BEHAVIOR.JUMP_EAST), "east")
  Assert.equal(MetatileBehavior.ledgeDirection(BEHAVIOR.JUMP_NORTH), "north")
  Assert.equal(MetatileBehavior.ledgeDirection(BEHAVIOR.JUMP_WEST), "west")
  Assert.equal(MetatileBehavior.ledgeDirection(BEHAVIOR.JUMP_SOUTH), "south")
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
