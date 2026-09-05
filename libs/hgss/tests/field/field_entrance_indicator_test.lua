local Assert = require("tests.support.Assert")
local Indicator = require("libs.hgss.src.transition.FieldEntranceIndicator")
local MetatileBehavior = require("libs.hgss.src.world.MetatileBehavior")

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

T.tests["phase toggles on the sixteenth eligible update"] = function()
  local indicator = Indicator.new()
  local behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST
  for updateNumber = 1, 15 do
    local status = update(indicator, behavior, "east")
    Assert.equal(status.phase, 0, "the initial phase lasts through update " .. updateNumber)
    Assert.equal(status.counter, updateNumber)
  end
  local phaseOne = update(indicator, behavior, "east")
  Assert.equal(phaseOne.phase, 1, "the sixteenth eligible update toggles before drawing")
  Assert.equal(phaseOne.counter, 0)
  for updateNumber = 17, 31 do
    local status = update(indicator, behavior, "east")
    Assert.equal(status.phase, 1, "phase one lasts through update " .. updateNumber)
    Assert.equal(status.counter, updateNumber - 16)
  end
  local phaseZero = update(indicator, behavior, "east")
  Assert.equal(phaseZero.phase, 0, "the thirty-second eligible update toggles back before drawing")
  Assert.equal(phaseZero.counter, 0)
end

T.tests["presentation offset changes on update sixteen and returns on update thirty two"] = function()
  local indicator = Indicator.new()
  local behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST
  local first = update(indicator, behavior, "east")
  Assert.deepEqual(first.position, { x = 65, y = 3, z = 80 })

  for _ = 2, 15 do
    update(indicator, behavior, "east")
  end
  local update16 = update(indicator, behavior, "east")
  Assert.equal(update16.phase, 1)
  Assert.deepEqual(update16.position, { x = 65.125, y = 3, z = 80 })

  for _ = 17, 31 do
    update(indicator, behavior, "east")
  end
  local update32 = update(indicator, behavior, "east")
  Assert.equal(update32.phase, 0)
  Assert.deepEqual(update32.position, { x = 65, y = 3, z = 80 })
end

T.tests["ineligible updates reset the animation before requalification"] = function()
  local indicator = Indicator.new()
  local behavior = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST
  for _ = 1, 16 do
    update(indicator, behavior, "east")
  end
  local hidden = update(indicator, behavior, "north")
  Assert.isFalse(hidden.visible)
  Assert.equal(hidden.phase, 0)
  Assert.equal(hidden.counter, 0)
  local restarted = update(indicator, behavior, "east")
  Assert.isTrue(restarted.visible)
  Assert.equal(restarted.phase, 0)
  Assert.equal(restarted.counter, 1)

  local transitionHidden = update(indicator, behavior, "east", false)
  Assert.isFalse(transitionHidden.visible)
  Assert.equal(transitionHidden.phase, 0)
  Assert.equal(transitionHidden.counter, 0)
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
