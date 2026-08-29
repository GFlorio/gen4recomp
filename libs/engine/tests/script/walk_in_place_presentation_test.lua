local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")

local T = {}

function T.walk_in_place_must_animate_without_translating()
  local fakeAssets = {
    knows = function()
      return true
    end,
    acquire = function(_, id)
      return { spriteId = id }
    end,
    release = function() end,
  }
  local policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }
  local TerrainSurface = require("libs.engine.src.TerrainSurface")
  local FieldEventState = require("libs.engine.src.FieldEventState")
  local function flatTerrain()
    return TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    })
  end
  local function map(objects)
    return {
      mapId = 61,
      coordinateOrigin = { x = 0, z = 0 },
      collision = {
        containsLocal = function(_, x, z)
          return x >= 0 and x < 32 and z >= 0 and z < 32
        end,
      },
      terrain = flatTerrain(),
      fieldData = { events = { objects = objects, background = {}, warps = {}, coordinates = {} } },
    }
  end
  local mgr = FieldActorManager.new({ assets = fakeAssets, policy = policy })
  mgr:enterMap(
    map({
      {
        objectEventId = 0,
        spriteId = 99,
        movement = 0,
        type = 0,
        eventFlag = 0,
        scriptId = 1,
        facingDirection = "south",
        facingDirectionRaw = 1,
        param0 = 0,
        param1 = 0,
        param2 = 0,
        xRange = 0,
        yRange = 0,
        x = 2,
        z = 3,
        y = 0,
      },
    }),
    FieldEventState.new()
  )

  local actorId = "map:61:object:0"
  local actor = assert(mgr:getById(actorId))
  local committedFieldX, committedFieldZ = actor.fieldX, actor.fieldZ
  local wx0, wz0 = assert(actor.worldX), assert(actor.worldZ)

  -- Simulate a walk_in_place presentation cycle: pose must advance while world and
  -- committed field stay fixed.
  mgr:beginScriptedAction(actorId, { action = "walk_in_place", direction = "south", speed = "normal" })
  Assert.notNil(actor:scriptedMotionState(), "walk_in_place must start scripted motion")
  mgr:advanceScriptedAction(actorId, 1, 8)
  Assert.equal(actor.pose, "walk", "walk_in_place must use walking pose")
  Assert.equal(actor.poseTick, 1, "pose clock must advance during walk_in_place")
  Assert.near(assert(actor.worldX), wx0, 1e-9, "walk_in_place must not translate worldX")
  Assert.near(assert(actor.worldZ), wz0, 1e-9, "walk_in_place must not translate worldZ")
  mgr:commitScriptedAction(actorId)
  Assert.equal(actor.fieldX, committedFieldX, "walk_in_place must not change committed fieldX")
  Assert.equal(actor.fieldZ, committedFieldZ, "walk_in_place must not change committed fieldZ")
  Assert.near(assert(actor.worldX), wx0, 1e-9, "walk_in_place commit keeps worldX at source")
  Assert.isNil(actor:scriptedMotionState(), "walk_in_place commit clears scripted motion")
end

return { tests = T }
