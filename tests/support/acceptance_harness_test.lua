-- Acceptance movement helpers must preserve route and stop-map behavior while
-- avoiding a full route search after every successful tile step.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local DELTAS = {
  north = { x = 0, z = -1 },
  south = { x = 0, z = 1 },
  west = { x = -1, z = 0 },
  east = { x = 1, z = 0 },
}

local function fakePlayer(metrics)
  local player = {
    fieldX = 0,
    fieldZ = 0,
    motion = "idle",
    facing = "south",
    metrics = metrics,
    currentMap = nil,
  }

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

local function fakeRuntime(metrics)
  local map = { mapId = 1, fieldData = { events = { warps = {} } } }
  local player = fakePlayer(metrics)
  player.currentMap = map
  local runtime = {
    player = player,
    runtimeMap = map,
    session = { FIXED_DT = 1 / 30 },
    pendingDirection = nil,
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
    if self.player.fieldX == 3 then
      self.runtimeMap.mapId = 2
    end
  end

  function runtime:dispose() end

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

return T
