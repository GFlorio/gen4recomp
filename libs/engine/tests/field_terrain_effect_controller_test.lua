-- FieldTerrainEffectController tests ownership, fixed-tick lifetime, and
-- global-anchor projection independently from GPU rendering.

local Assert = require("tests.support.Assert")
local FieldTerrainEffectController = require("libs.engine.src.FieldTerrainEffectController")
local ModelInstance = require("libs.engine.src.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = { metadata = { capabilities = {} }, tests = {} }

local function definition(lifetime, kind)
  return {
    definition = "renderer-" .. kind,
    model = { animations = { { name = "grass", frameCount = lifetime } } },
  }
end

local function controller()
  local function factory(_, source)
    local player = { frameFx = 0, frameCount = source.model.animations[1].frameCount, complete = false }
    function player:updateFixed()
      self.frameFx = self.frameFx + 4096
      if self.frameFx >= self.frameCount * 4096 then
        self.frameFx = self.frameCount * 4096
        self.complete = true
      end
    end
    function player:isComplete()
      return self.complete
    end
    local instance = {}
    function instance:play()
      return { player = player }
    end
    function instance:updateFixed()
      player:updateFixed()
    end
    return instance
  end
  return FieldTerrainEffectController.new({
    effects = {
      tall_grass = definition(3, 8),
      very_tall_grass = definition(2, 12),
    },
    modelFactory = factory,
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
        model = { animations = { { name = "grass", frameCount = 3 } } },
      },
    },
    modelFactory = function(_, source)
      local player = { frameFx = 0, frameCount = source.model.animations[1].frameCount, complete = false }
      function player:updateFixed()
        self.frameFx = self.frameFx + 4096
        if self.frameFx >= self.frameCount * 4096 then
          self.frameFx = self.frameCount * 4096
          self.complete = true
        end
      end
      function player:isComplete()
        return self.complete
      end
      local instance = {}
      function instance:play()
        return { player = player }
      end
      function instance:updateFixed()
        player:updateFixed()
      end
      return instance
    end,
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

T.tests["dynamic grass instances change pose independently from their semantic age"] = function()
  local clip = NitroModelFixture.doorOpenClip()
  local effectDefinition = { model = { animations = { { name = clip.name, frameCount = clip.frameCount } } } }
  local effects = FieldTerrainEffectController.new({
    effects = { tall_grass = effectDefinition },
    modelFactory = function()
      local instance = ModelInstance.new(NitroModelFixture.doorDefinition({ clip }))
      instance.renderMeshesById = { ["draw0.seg0"] = {} }
      return instance
    end,
  })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "east" })
  local first = effects:status().instances[1].modelInstance
  first:evaluatePose()
  local firstTransform = first:drawItems(first.renderMeshesById)[1].transform
  Assert.equal(effects:status().instances[1].frame, 0)

  effects:updateFixed()
  local second = effects:status().instances[1].modelInstance
  second:evaluatePose()
  local secondTransform = second:drawItems(second.renderMeshesById)[1].transform
  Assert.isFalse(firstTransform[1] == secondTransform[1] and firstTransform[3] == secondTransform[3])
end

return T
