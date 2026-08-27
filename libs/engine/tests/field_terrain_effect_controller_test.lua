-- FieldTerrainEffectController tests ownership and fixed-tick lifetime
-- independently from GPU rendering.

local Assert = require("tests.support.Assert")
local FieldTerrainEffectController = require("libs.engine.src.FieldTerrainEffectController")
local ModelInstance = require("libs.engine.src.ModelInstance")
local NitroModelFixture = require("tests.support.NitroModelFixture")

local T = { metadata = { capabilities = {} }, tests = {} }

local function updateWithOwner(effects, owner)
  local update = effects.updateFixed
  ---@cast update fun(self: table, owner: table)
  return update(effects, owner)
end

local function definition(kind)
  return {
    definition = "renderer-" .. kind,
    lifecycle = {
      holdFrame = 12,
      holdUntilOwnerMoves = true,
    },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = "grass", frameCount = 13 } } },
  }
end

local function genericDefinition(kind)
  kind = kind or "tall_grass"
  return {
    definition = "renderer-" .. kind,
    lifecycle = {
      holdFrame = 3,
      holdUntilOwnerMoves = true,
    },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = "grass", frameCount = 4 } } },
  }
end

local function controller(players, definitions)
  definitions = definitions
    or {
      tall_grass = definition("tall_grass"),
      very_tall_grass = definition("very_tall_grass"),
    }
  local function factory(_, source)
    local player = {
      frameFx = 0,
      frameCount = source.model.animations[1].frameCount,
      complete = false,
      updateCount = 0,
    }
    function player:updateFixed()
      self.updateCount = self.updateCount + 1
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
    if players then
      players[#players + 1] = player
    end
    return instance
  end
  return FieldTerrainEffectController.new({
    effects = definitions,
    modelFactory = factory,
  })
end

T.tests["instances retain distinct semantic anchors"] = function()
  local effects = controller()
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 2, worldY = 4, direction = "east" })
  effects:emit({ kind = "tall_grass", fieldX = 2, fieldZ = 2, worldY = 4, direction = "east" })
  Assert.equal(#effects:status().instances, 2)
  Assert.equal(effects:status().instances[1].fieldX, 1)
  Assert.equal(effects:status().instances[2].fieldX, 2)
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

T.tests["grass intro completes before owner displacement retires it"] = function()
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    local players = {}
    local effects = controller(players, { [kind] = genericDefinition(kind) })
    effects:emit({ kind = kind, fieldX = 7, fieldZ = 9, worldY = 3.5, direction = "north" })

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "north" })
    local first = effects:status().instances[1]
    Assert.notNil(first)
    Assert.equal(first.age, 1)
    Assert.equal(first.frame, 1)

    for tick = 2, 3 do
      updateWithOwner(effects, { fieldX = 8, fieldZ = 9, facing = "north" })
      local instance = effects:status().instances[1]
      Assert.notNil(instance)
      Assert.equal(instance.age, tick)
      Assert.equal(instance.frame, tick)
    end
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 8, fieldZ = 9, facing = "north" })
    Assert.equal(#effects:status().instances, 0)
  end
end

T.tests["grass facing changes only retire held instances"] = function()
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    local players = {}
    local effects = controller(players, { [kind] = genericDefinition(kind) })
    effects:emit({ kind = kind, fieldX = 7, fieldZ = 9, worldY = 3.5, direction = "north" })

    for tick = 1, 3 do
      updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "east" })
      local instance = effects:status().instances[1]
      Assert.notNil(instance)
      Assert.equal(instance.age, tick)
      Assert.equal(instance.frame, tick)
    end
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "north" })
    local held = effects:status().instances[1]
    Assert.notNil(held)
    Assert.equal(held.frame, 3)
    Assert.equal(players[1].updateCount, 3)

    updateWithOwner(effects, { fieldX = 7, fieldZ = 9, facing = "east" })
    Assert.equal(#effects:status().instances, 0)
  end
end

T.tests["held grass removals do not skip neighboring instances"] = function()
  local effects = controller(nil, { tall_grass = genericDefinition("tall_grass") })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "north" })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "east" })
  effects:emit({ kind = "tall_grass", fieldX = 1, fieldZ = 1, worldY = 0, direction = "south" })

  for _ = 1, 3 do
    updateWithOwner(effects, { fieldX = 1, fieldZ = 1, facing = "north" })
  end
  updateWithOwner(effects, { fieldX = 1, fieldZ = 1, facing = "north" })

  local instances = effects:status().instances
  Assert.equal(#instances, 1)
  Assert.equal(instances[1].fieldX, 1)
end

T.tests["dynamic grass instances change pose independently from their semantic age"] = function()
  local clip = NitroModelFixture.doorOpenClip()
  local effectDefinition = {
    lifecycle = { holdFrame = 12, holdUntilOwnerMoves = true },
    placementOffset = { x = 0.25, y = 0, z = -0.5 },
    model = { kind = "nitro-dynamic", animations = { { name = clip.name, frameCount = 13 } } },
  }
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

  effects:updateFixed({ fieldX = 1, fieldZ = 1, facing = "east" })
  local second = effects:status().instances[1].modelInstance
  second:evaluatePose()
  local secondTransform = second:drawItems(second.renderMeshesById)[1].transform
  Assert.isFalse(firstTransform[1] == secondTransform[1] and firstTransform[3] == secondTransform[3])
end

return T
