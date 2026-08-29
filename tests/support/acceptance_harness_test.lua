-- Acceptance movement helpers must preserve route and stop-map behavior while
-- avoiding a full route search after every successful tile step.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

-- `FieldMovement.route` plans through a disposable real `FieldPlayer` probe
-- (`FieldPlayer:resolveStep`), so the map needs real collision/terrain even
-- though the fake player below drives the actual walk itself.
local FLAT_PLATE = {
  id = 0,
  minX = 0,
  minZ = 0,
  maxX = 32,
  maxZ = 32,
  normal = { x = 0, y = 1, z = 0 },
  distance = 0,
  slopeClass = "flat",
}

local function flatMap()
  return {
    mapId = 1,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({ plates = { FLAT_PLATE } }),
    fieldData = { events = { warps = {}, coordinates = {} } },
  }
end

local function fakePlayer(metrics)
  local player = {
    fieldX = 0,
    fieldZ = 0,
    surfaceId = 0,
    motion = "idle",
    facing = "south",
    metrics = metrics,
    currentMap = nil,
  }

  function player:turn(direction)
    self.facing = direction
  end

  function player:tryStep(direction)
    self.metrics.tryStepCalls = self.metrics.tryStepCalls + 1
    local delta = assert(DELTAS[direction])
    self.facing = direction
    self.pending = { fieldX = self.fieldX + delta.x, fieldZ = self.fieldZ + delta.z }
    self.motion = "walking"
    return true
  end

  function player:updateFixed(_)
    if self.motion ~= "walking" then
      return false
    end
    self.fieldX, self.fieldZ = self.pending.fieldX, self.pending.fieldZ
    self.pending = nil
    self.motion = "idle"
    return true
  end

  return player
end

local function fakeRuntime(metrics, changeMapAt)
  local map = flatMap()
  local player = fakePlayer(metrics)
  player.currentMap = map
  local runtime = {
    player = player,
    runtimeMap = map,
    session = { FIXED_DT = 1 / 30 },
    pendingDirection = nil,
    eventState = {
      getVar = function()
        return 0
      end,
    },
  }

  function runtime:press(direction)
    self.pendingDirection = direction
  end

  function runtime:release()
    self.pendingDirection = nil
  end

  function runtime:update()
    local direction = self.pendingDirection
    if not direction then
      return
    end
    assert(self.player:tryStep(direction))
    self.player:updateFixed({})
    if changeMapAt ~= false and self.player.fieldX == 3 then
      self.runtimeMap.mapId = 2
    end
  end

  function runtime:dispose() end

  -- The harness boot contract requires a capture entry point regardless of
  -- what a test actually exercises; this fake never persists anything.
  function runtime:captureGameSave()
    return { saveId = "fake-save", versionId = "test" }
  end

  return runtime
end

local T = { metadata = { capabilities = {} }, tests = {} }

function T.tests.move_to_reuses_a_route_until_the_stop_map()
  local metrics = { tryStepCalls = 0 }
  local runtime = fakeRuntime(metrics)
  local harness = AcceptanceHarness.new({
    versions = { "test" },
    runtimeFactory = function()
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-harness-test"
    end,
    removeSaveNamespace = function() end,
  })
  local game = harness:boot({ versionId = "test", save = "fresh" })
  local ok, err = xpcall(function()
    local snapshot = game:moveTo({ fieldX = 6, fieldZ = 0 }, 2)
    Assert.equal(snapshot.mapId, 2)
    Assert.equal(snapshot.player.fieldX, 3)
    Assert.equal(snapshot.player.fieldZ, 0)
    Assert.isTrue(metrics.tryStepCalls < 400, "moveTo must not replan after every tile")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

function T.tests.move_to_prefers_a_direct_route_through_a_large_open_area()
  local metrics = { tryStepCalls = 0 }
  local runtime = fakeRuntime(metrics, false)
  local harness = AcceptanceHarness.new({
    versions = { "test" },
    runtimeFactory = function()
      return runtime
    end,
    saveNamespace = function()
      return "acceptance-harness-open-area-test"
    end,
    removeSaveNamespace = function() end,
  })
  local game = harness:boot({ versionId = "test", save = "fresh" })
  local ok, err = xpcall(function()
    local snapshot = game:moveTo({ fieldX = 12, fieldZ = 0 })
    Assert.equal(snapshot.player.fieldX, 12)
    Assert.equal(snapshot.player.fieldZ, 0)
    Assert.isTrue(
      metrics.tryStepCalls < 100,
      "moveTo must prioritize the target instead of exploring the whole wavefront: " .. metrics.tryStepCalls
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
