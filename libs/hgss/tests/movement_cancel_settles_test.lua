local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.hgss.src.field.FieldActorManager")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

function T.cancelled_movement_must_settle_to_last_committed_anchor()
  local fakeAssets = {
    knows = function()
      return true
    end,
    acquire = function(_, id)
      return { spriteId = id, visual = FieldActorFixture.visual(id) }
    end,
    release = function() end,
  }
  local policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } }
  local TerrainSurface = require("libs.hgss.src.field.TerrainSurface")
  local FieldEventState = require("libs.hgss.src.field.FieldEventState")
  local FieldCoordinates = require("libs.hgss.src.field.FieldCoordinates")
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
    local result = {
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
    ---@cast result RuntimeFieldMap
    return result
  end
  local mgr = FieldActorManager.new({ assets = fakeAssets, policy = policy })
  mgr:enterMap(
    map({
      {
        objectEventId = 0,
        spriteId = 99,
        movementType = "stationary",
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
  local committed = { fieldX = actor.fieldX, fieldZ = actor.fieldZ, surfaceId = actor.surfaceId }
  local expectedWorld = FieldCoordinates.fieldToWorld(map({}), committed.fieldX, committed.fieldZ, 0)

  -- Starting a scripted walk advances presentation world; cancelling must
  -- collapse it back to the committed anchor.
  mgr:beginScriptedAction(actorId, { action = "walk", direction = "east", speed = "normal" })
  mgr:advanceScriptedAction(actorId, 4, 8)
  Assert.isTrue(
    actor.worldX ~= expectedWorld.x or actor.worldZ ~= expectedWorld.z,
    "precondition: mid-walk presentation is offset"
  )

  -- Mid-motion cancel must restore committed position.
  mgr:cancelScriptedMovement(actorId)
  Assert.near(actor.worldX, expectedWorld.x, 1e-9, "cancel must settle worldX to last committed anchor")
  Assert.near(actor.worldZ, expectedWorld.z, 1e-9, "cancel must settle worldZ to last committed anchor")
  Assert.equal(actor.fieldX, committed.fieldX, "cancel must keep committed fieldX")
  Assert.equal(actor.fieldZ, committed.fieldZ, "cancel must keep committed fieldZ")
  Assert.isFalse(actor:isScriptedMoving(), "cancel must clear scripted motion")
  Assert.equal(
    mgr:isOccupied(61, { fieldX = committed.fieldX, fieldZ = committed.fieldZ, surfaceId = committed.surfaceId }),
    true,
    "occupancy stays on committed tile after cancel"
  )

  -- Idle cancel must also settle any fractional drift.
  actor.worldX = expectedWorld.x + 0.7
  actor.worldZ = expectedWorld.z + 0.3
  mgr:cancelScriptedMovement(actorId)
  Assert.near(actor.worldX, expectedWorld.x, 1e-9, "idle cancel must settle fractional worldX drift")
  Assert.near(actor.worldZ, expectedWorld.z, 1e-9, "idle cancel must settle fractional worldZ drift")
end

return { tests = T }
