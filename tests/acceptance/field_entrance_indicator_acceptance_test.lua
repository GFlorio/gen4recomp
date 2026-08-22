-- Production-composed contracts for the HGSS directional warp-entrance field
-- effect. The runtime is booted from the real ROM-derived map/cache and the
-- render trap keeps every scenario before GPU rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "warp-entrance", "indicator", "asset-readiness" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB_2F = "MAP_NEW_BARK_ELMS_LAB_2F"

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = map, save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the indicator contract must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

local function entranceCell(game, behavior)
  local map = game.runtime.runtimeMap
  local origin = assert(map.coordinateOrigin, "the production map must expose a coordinate origin")
  for _, warp in ipairs(map.fieldData.events.warps) do
    local localX, localZ = warp.x - origin.x, warp.z - origin.z
    if map.collision:containsLocal(localX, localZ) then
      local cell = map.collision:getLocal(localX, localZ)
      if cell.behavior == behavior then
        return { fieldX = warp.x, fieldZ = warp.z }
      end
    end
  end
  return nil
end

local function enterLab2F(game)
  game:moveTo({ fieldX = 688, fieldZ = 392 })
  game:face("west")
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, LAB_2F)
end

local function indicatorStatus(game)
  local indicator = game.runtime.fieldEntranceIndicator
  Assert.notNil(indicator, "the production field runtime must expose the directional entrance indicator state")
  local status = indicator:status()
  Assert.notNil(status, "the production indicator must expose a presentation-neutral status")
  return status
end

T.tests["east entrance indicator tracks facing and resets"] = function()
  withGame(TOWN, function(game)
    enterLab2F(game)
    local cell = assert(
      entranceCell(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
      "Elm Lab 2F must expose the east entrance tile"
    )
    game:moveTo(cell)
    game.runtime.player.facing = "east"
    game:step()
    local east = indicatorStatus(game)
    Assert.isTrue(east.visible, "the east entrance indicator must be visible while facing east")
    Assert.equal(east.direction, "east")
    Assert.equal(east.rotationDegrees, 90)
    Assert.equal(east.phase, 0)

    game.runtime.player.facing = "north"
    game:step()
    local away = indicatorStatus(game)
    Assert.isFalse(away.visible, "turning away must hide the entrance indicator")
    Assert.equal(away.phase, 0, "turning away must reset the source animation phase")

    game.runtime.player.facing = "east"
    game:step()
    local eastAgain = indicatorStatus(game)
    Assert.isTrue(eastAgain.visible)
    Assert.equal(eastAgain.phase, 0, "matching facing after a reset must restart at phase zero")
  end)
end

T.tests["only entrance behaviors are indicator eligible"] = function()
  withGame(TOWN, function(game)
    local indicator = game.runtime.fieldEntranceIndicator
    Assert.notNil(indicator, "the production field runtime must expose the indicator state")
    local cases = {
      { MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH, "north" },
      { MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_SOUTH, "south" },
      { MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_WEST, "west" },
      { MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST, "east" },
      { MetatileBehavior.BEHAVIOR.WARP_NORTH, nil },
      { MetatileBehavior.BEHAVIOR.WARP_STAIRS_EAST, nil },
      { MetatileBehavior.BEHAVIOR.DOOR, nil },
      { 0, nil },
    }
    for _, case in ipairs(cases) do
      local status = indicator:updateFixed({
        map = game.runtime.runtimeMap,
        player = { behavior = case[1], facing = case[2] or "north" },
        transition = { ownsField = true },
      })
      if case[2] then
        Assert.equal(status.direction, case[2])
        Assert.isTrue(status.visible, "matching entrance behavior/facing must qualify")
      else
        Assert.isFalse(status.visible, "generic warp geometry must not qualify as an entrance effect")
      end
    end
  end)
end

T.tests["two-phase motion is fixed-step and source-calibrated"] = function()
  withGame(TOWN, function(game)
    enterLab2F(game)
    local indicator = game.runtime.fieldEntranceIndicator
    Assert.notNil(indicator, "the production field runtime must expose the indicator state")
    local cell = assert(
      entranceCell(game, MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_EAST),
      "the production map must expose an entrance behavior for phase sampling"
    )
    game.runtime.player.fieldX, game.runtime.player.fieldZ = cell.fieldX, cell.fieldZ
    game.runtime.player.facing = "east"
    game:step()

    local samples = {}
    for tick = 1, 33 do
      samples[tick] = indicatorStatus(game)
      game:step()
    end
    Assert.equal(samples[1].phase, 0)
    Assert.equal(samples[17].phase, 1, "the source phase must toggle after 16 eligible updates")
    Assert.equal(samples[33].phase, 0, "the source phase must toggle back after another 16 updates")
    Assert.notNil(samples[1].offset, "the status must expose the source-calibrated world offset")
    Assert.notNil(samples[17].offset, "both source phases must expose a world offset")
    Assert.isFalse(
      samples[1].offset.x == samples[17].offset.x
        and samples[1].offset.y == samples[17].offset.y
        and samples[1].offset.z == samples[17].offset.z,
      "the two phases must move the world effect"
    )
  end)
end

T.tests["the canonical model is required by cache readiness"] = function()
  withGame(TOWN, function(game)
    local asset = game.runtime.fieldEntranceIndicatorAsset
    Assert.notNil(asset, "production boot must resolve the ROM-derived entrance-effect asset")
    Assert.equal(asset.model.key, "field-effect:warp-entrance")
    Assert.notNil(asset.model.batches, "the readiness contract must expose model batches")
    Assert.notNil(asset.model.materials, "the readiness contract must expose model materials")
    Assert.equal(#recordsNamed(game, "asset.fallback_draw"), 0, "the effect must not use a synthetic fallback")
  end)
end

return T
