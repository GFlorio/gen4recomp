-- FieldTerrainEffectController tests ownership, fixed-tick lifetime, and
-- global-anchor projection independently from GPU rendering.

local Assert = require("tests.support.Assert")
local FieldTerrainEffectController = require("libs.engine.src.FieldTerrainEffectController")

local T = { metadata = { capabilities = {} }, tests = {} }

local function animation(lifetime)
  return { frames = { { duration = lifetime } } }
end

local function controller()
  return FieldTerrainEffectController.new({
    effects = {
      tall_grass = { definition = "renderer-8", lifetime = 3, animation = animation(3) },
      very_tall_grass = { definition = "renderer-12", lifetime = 2, animation = animation(2) },
    },
  })
end

T.tests["instances overlap and expire independently"] = function()
  local effects = controller()
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 2, worldY = 4, direction = "east" })
  effects:emit({ kind = "tall_grass", fieldX = 2, fieldZ = 2, worldY = 4, direction = "east" })
  Assert.equal(#effects:status().instances, 2)
  effects:updateFixed()
  effects:updateFixed()
  Assert.equal(#effects:status().instances, 2)
  effects:updateFixed()
  Assert.equal(#effects:status().instances, 0)
end

T.tests["global anchors project against the current coverage origin"] = function()
  local effects = controller()
  effects:emit({ kind = "very_tall_grass", fieldX = 34, fieldZ = 5, worldY = 7, direction = "north" })
  local first = effects:drawItems({ x = 32, z = 0 })[1]
  local second = effects:drawItems({ x = 0, z = 0 })[1]
  Assert.equal(first.localX, 2)
  Assert.equal(second.localX, 34)
  Assert.equal(first.worldY, 7)
end

T.tests["grass instances retain stable source-surface identity"] = function()
  local effects = controller()
  effects:emit({
    kind = "tall_grass",
    fieldX = 34,
    fieldZ = 5,
    worldY = 7,
    direction = "north",
    cellKey = "1:0",
    sourceSurfaceId = 3,
  })
  local instance = effects:status().instances[1]
  Assert.equal(instance.cellKey, "1:0")
  Assert.equal(instance.sourceSurfaceId, 3)
end

T.tests["discontinuous clear disposes all transient instances"] = function()
  local effects = controller()
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "south" })
  effects:clear()
  Assert.equal(#effects:status().instances, 0)
end

T.tests["committed grass animation completion controls effect lifetime"] = function()
  local effects = FieldTerrainEffectController.new({
    effects = {
      tall_grass = {
        definition = "field-effect:tall-grass",
        lifetime = 99,
        animation = { frames = { { duration = 1 }, { duration = 2 } } },
      },
    },
  })
  effects:emit({ kind = "tall_grass", fieldX = 7, fieldZ = 9, worldY = 3.5, direction = "north" })
  Assert.equal(#effects:status().instances, 1)
  effects:updateFixed()
  Assert.equal(#effects:status().instances, 1)
  effects:updateFixed()
  Assert.equal(#effects:status().instances, 1)
  effects:updateFixed()
  Assert.equal(#effects:status().instances, 0, "the source animation's three ticks complete the effect")
end

return T
