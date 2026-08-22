local Assert = require("tests.support.Assert")
local Indicator = require("libs.engine.src.FieldEntranceIndicator")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

local T = { tests = {} }

local function update(indicator, behavior, facing, ownsField)
  return indicator:updateFixed({
    map = { terrain = {
      sampleHeight = function()
        return 3
      end,
    } },
    player = { fieldX = 4, fieldZ = 5, behavior = behavior, facing = facing, worldX = 64, worldY = 3, worldZ = 80 },
    transition = { ownsField = ownsField ~= false },
  })
end

T.tests["only matching entrance behavior is visible"] = function()
  local indicator = Indicator.new()
  local behaviors = MetatileBehavior.BEHAVIOR
  Assert.isTrue(update(indicator, behaviors.WARP_ENTRANCE_EAST, "east").visible)
  Assert.isFalse(update(indicator, behaviors.WARP_EAST, "east").visible)
  Assert.isFalse(update(indicator, behaviors.WARP_STAIRS_EAST, "east").visible)
  Assert.isFalse(update(indicator, behaviors.DOOR, "east").visible)
end

T.tests["phase advances in fixed steps and resets"] = function()
  local indicator = Indicator.new()
  local behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST
  Assert.equal(update(indicator, behavior, "east").phase, 0)
  for _ = 2, 16 do
    update(indicator, behavior, "east")
  end
  Assert.equal(update(indicator, behavior, "east").phase, 1)
  Assert.equal(update(indicator, behavior, "north").phase, 0)
  Assert.equal(update(indicator, behavior, "east").phase, 0)
  Assert.equal(update(indicator, behavior, "east", false).phase, 0)
end

T.tests["phase offsets match the directional source vectors"] = function()
  local behaviors = MetatileBehavior.BEHAVIOR
  local expected = {
    { behaviors.WARP_ENTRANCE_NORTH, "north", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = -0.125 } },
    { behaviors.WARP_ENTRANCE_SOUTH, "south", { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0.125 } },
    { behaviors.WARP_ENTRANCE_WEST, "west", { x = 0, y = 0, z = 0 }, { x = -0.125, y = 0, z = 0 } },
    { behaviors.WARP_ENTRANCE_EAST, "east", { x = 0, y = 0, z = 0 }, { x = 0.125, y = 0, z = 0 } },
  }
  for _, case in ipairs(expected) do
    local indicator = Indicator.new()
    Assert.deepEqual(update(indicator, case[1], case[2]).offset, case[3])
    for _ = 2, 16 do
      update(indicator, case[1], case[2])
    end
    Assert.deepEqual(update(indicator, case[1], case[2]).offset, case[4])
  end
end

T.tests["eligibility does not require presentation world coordinates"] = function()
  local indicator = Indicator.new()
  local status = indicator:updateFixed({
    map = { terrain = {
      sampleHeight = function()
        return 3
      end,
    } },
    player = {
      behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST,
      facing = "east",
    },
    transition = { ownsField = true },
  })
  Assert.isTrue(status.visible)
  Assert.equal(status.direction, "east")
  Assert.isNil(status.position)
end

return T
