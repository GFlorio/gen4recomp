-- FieldTerrainResponse maps a committed destination behavior to a semantic
-- presentation response without depending on runtime or presentation state.

local Assert = require("tests.support.Assert")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")
local FieldTerrainResponse = require("libs.engine.src.FieldTerrainResponse")

local T = { metadata = { capabilities = {} }, tests = {} }

local function resolve(behavior)
  return FieldTerrainResponse.resolve({
    committed = true,
    destination = {
      behavior = behavior,
      fieldX = 12,
      fieldZ = 18,
      worldY = 2.5,
    },
    direction = "north",
  })
end

T.tests["grass behaviors produce distinct destination responses"] = function()
  local tall = resolve(MetatileBehavior.BEHAVIOR.TALL_GRASS)
  Assert.equal(#tall, 1)
  Assert.equal(tall[1].kind, "tall_grass")
  Assert.equal(tall[1].fieldX, 12)
  Assert.equal(tall[1].fieldZ, 18)
  Assert.equal(tall[1].worldY, 2.5)
  Assert.equal(tall[1].direction, "north")

  local veryTall = resolve(MetatileBehavior.BEHAVIOR.VERY_TALL_GRASS)
  Assert.equal(#veryTall, 1)
  Assert.equal(veryTall[1].kind, "very_tall_grass")
end

T.tests["uncommitted or non-grass movement produces no response"] = function()
  Assert.equal(#resolve(0), 0)
  local result = FieldTerrainResponse.resolve({
    committed = false,
    destination = { behavior = MetatileBehavior.BEHAVIOR.TALL_GRASS, fieldX = 1, fieldZ = 1, worldY = 0 },
    direction = "south",
  })
  Assert.equal(#result, 0)
end

return T
