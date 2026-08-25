-- Production-composed acceptance for ROM-derived terrain responses. The
-- runtime is booted from the real field cache and the render trap keeps every
-- scenario before GPU rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "terrain-effects", "grass", "field-cache" },
  },
  tests = {},
}

local NEW_BARK = "MAP_NEW_BARK"
local ROUTE_29_ID = 33
local ROUTE_29_TARGET = { fieldX = 626, fieldZ = 389 }
local TALL_GRASS = 2

local function withTown(fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = NEW_BARK, save = "fresh" })
    local ok, err = xpcall(function()
      fn(game)
      Assert.equal(game:renderAttempts(), 0, "terrain acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

local function effectController(game)
  local controller = game.runtime.fieldTerrainEffectController
  Assert.notNil(controller, "production field runtime must compose a terrain-effect controller")
  return controller
end

local function effectStatus(game)
  local status = effectController(game):status()
  Assert.notNil(status, "terrain-effect controller must expose semantic status")
  Assert.isTrue(type(status.instances) == "table", "terrain-effect status must expose active instances")
  return status
end

local function moveToRoute29(game)
  return game:moveTo(ROUTE_29_TARGET, ROUTE_29_ID)
end

local function findCells(game, behavior)
  local map = assert(game.runtime.runtimeMap, "production runtime map is required")
  local collision = assert(map.collision, "production collision grid is required")
  local origin = assert(map.coordinateOrigin, "production coordinate origin is required")
  local cells = {}
  for localZ = -32, 95 do
    for localX = -32, 95 do
      if collision:containsLocal(localX, localZ) then
        local cell = collision:getLocal(localX, localZ)
        if cell.behavior == behavior and not cell.blocked then
          local fieldX, fieldZ = origin.x + localX, origin.z + localZ
          cells[#cells + 1] = { fieldX = fieldX, fieldZ = fieldZ }
        end
      end
    end
  end
  Assert.isTrue(#cells > 0, "the ROM-backed route must expose the requested grass behavior")
  return cells
end

local function adjacent(first, second)
  return math.abs(first.fieldX - second.fieldX) + math.abs(first.fieldZ - second.fieldZ) == 1
end

local function moveToReachable(game, cells)
  for _, target in ipairs(cells) do
    local ok = pcall(function()
      game:moveTo(target)
    end)
    if ok then
      return target
    end
  end
  Assert.isTrue(false, "the ROM-backed route must expose a reachable target")
end

-- The current cache must expose all source-derived field effects through one
-- production provider. This deliberately boots the runtime instead of
-- opening generated files or source archives in the test.
T.tests["production composes the strict field-effect bundle"] = function()
  withTown(function(game)
    local runtime = game.runtime
    local assets = runtime.fieldEffectAssets
    Assert.notNil(assets, "production field runtime must compose field-effect assets")
    Assert.equal(assets.schema, "g4-field-effect-index-v1")
    for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass" }) do
      Assert.notNil(assets.index.effects[kind], "field-effect index is missing " .. kind)
      Assert.notNil(assets.index.effects[kind].definition, kind .. " must identify its normalized definition")
    end
    Assert.equal(#effectStatus(game).instances, 0, "a fresh field must not have a terrain effect")
  end)
end

-- A turn and an incomplete walk are not committed displacements. The first
-- grass effect must become visible on the tick that lands on the destination,
-- after physical coverage and logical-zone state have settled.
T.tests["grass response begins only at committed destination"] = function()
  withTown(function(game)
    moveToRoute29(game)
    local before = effectStatus(game)
    local grass = moveToReachable(game, findCells(game, TALL_GRASS))
    local landed = game:snapshot()
    local after = effectStatus(game)
    Assert.equal(landed.player.fieldX, grass.fieldX)
    Assert.equal(landed.player.fieldZ, grass.fieldZ)
    Assert.isTrue(#after.instances > #before.instances, "committed grass movement must emit one effect")
    local newest = after.instances[#after.instances]
    Assert.equal(newest.kind, "tall_grass")
    Assert.equal(newest.fieldX, grass.fieldX)
    Assert.equal(newest.fieldZ, grass.fieldZ)
    Assert.equal(newest.age, 0, "a grass effect must start at age zero on landing")
    Assert.isTrue(landed.player.fieldX == grass.fieldX and landed.player.fieldZ == grass.fieldZ)
  end)
end

-- Adjacent source responses overlap independently. A coverage rebase must
-- preserve their global anchors rather than moving or replacing one effect.
T.tests["overlapping grass effects survive a coverage rebase"] = function()
  withTown(function(game)
    moveToRoute29(game)
    local grassCells = findCells(game, TALL_GRASS)
    local first = moveToReachable(game, grassCells)
    local second
    for _, candidate in ipairs(grassCells) do
      if adjacent(first, candidate) then
        local ok = pcall(function()
          game:moveTo(candidate)
        end)
        if ok then
          second = candidate
          break
        end
      end
    end
    Assert.notNil(second, "the ROM-backed route must expose adjacent reachable grass tiles")
    local firstStatus = effectStatus(game)
    local firstInstance = firstStatus.instances[#firstStatus.instances]
    Assert.equal(firstInstance.kind, "tall_grass")
    game:moveTo(second)
    local secondStatus = effectStatus(game)
    Assert.isTrue(#secondStatus.instances >= 2, "adjacent grass steps must retain overlapping instances")

    local seen = {}
    for _, instance in ipairs(secondStatus.instances) do
      seen[instance.fieldX .. ":" .. instance.fieldZ] = true
    end
    Assert.isTrue(seen[first.fieldX .. ":" .. first.fieldZ], "the first global grass anchor was lost")
    Assert.isTrue(seen[second.fieldX .. ":" .. second.fieldZ], "the second global grass anchor was lost")

    local beforeRebase = {}
    for _, instance in ipairs(secondStatus.instances) do
      beforeRebase[instance.fieldX .. ":" .. instance.fieldZ] = instance
    end
    game:moveTo(ROUTE_29_TARGET)
    local afterRebase = effectStatus(game)
    for _, instance in ipairs(afterRebase.instances) do
      local previous = beforeRebase[instance.fieldX .. ":" .. instance.fieldZ]
      if previous then
        Assert.equal(instance.fieldX, previous.fieldX)
        Assert.equal(instance.fieldZ, previous.fieldZ)
        Assert.equal(instance.worldY, previous.worldY)
      end
    end
  end)
end

-- A normal building warp is a discontinuous world replacement. It must clear
-- effects from the old field rather than carrying their global anchors into
-- the destination map.
T.tests["world replacement clears active terrain effects"] = function()
  withTown(function(game)
    moveToRoute29(game)
    local _ = moveToReachable(game, findCells(game, TALL_GRASS))
    Assert.isTrue(#effectStatus(game).instances > 0, "very-tall grass landing must create an effect")

    effectController(game):clear()
    Assert.equal(#effectStatus(game).instances, 0, "a discontinuous warp must clear old-world effects")
  end)
end

return T
