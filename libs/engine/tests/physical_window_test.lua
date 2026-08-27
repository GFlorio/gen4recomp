-- Physical-cell ownership tests use deterministic CPU cell runtimes. The
-- presentation records stand in for the cell-owned render resources that the
-- live field window must acquire and release with the simulation resources.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.FieldCellCache")
local FieldCoverage = require("libs.engine.src.FieldCoverage")

local T = {}
local activeReleaseCounts

local function cellKey(x, z)
  return string.format("%d:%d", x, z)
end

local function makeIndex(width, height)
  local cells = {}
  for z = 0, height - 1 do
    for x = 0, width - 1 do
      local index = z * width + x
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        mapHeaderId = (x == 0 and 33) or 60,
        altitude = 0,
        origin = { x = x * 32, y = (x + z) * 0.5, z = z * 32 },
        landDataMemberId = 1,
        areaDataMemberId = 1,
        file = FieldCellCache.cellPath(1, index),
      }
    end
  end
  return {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = { { matrixMemberId = 1, width = width, height = height, cells = cells } },
  }
end

local function makeRuntimeFactory(loads, releaseCounts)
  return function(descriptor)
    local key = cellKey(descriptor.x, descriptor.z)
    loads[key] = (loads[key] or 0) + 1
    local plate = {
      id = 0,
      minX = 0,
      maxX = 32,
      minZ = 0,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = descriptor.origin.y,
    }
    local collision = {
      cellKey = key,
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
      getLocal = function()
        return { blocked = false, cellKey = key }
      end,
    }
    local terrain = {
      cellKey = key,
      artifact = { source = { bdhcSha1 = key } },
      plates = { plate },
      candidatesAt = function()
        return { plate }
      end,
    }
    return {
      key = key,
      x = descriptor.x,
      z = descriptor.z,
      altitude = descriptor.altitude,
      origin = descriptor.origin,
      collision = collision,
      terrain = terrain,
      presentation = { cellKey = key },
      release = function()
        releaseCounts[key] = (releaseCounts[key] or 0) + 1
      end,
    }
  end
end

local function newCoverage(options)
  local loads, releaseCounts = {}, {}
  activeReleaseCounts = releaseCounts
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(options.width or 6, options.height or 3),
    anchorX = options.anchorX or 1,
    anchorZ = options.anchorZ or 1,
    loadCell = options.loadCell or makeRuntimeFactory(loads, releaseCounts),
    presentationLoader = options.presentationLoader,
  })
  return coverage, loads, releaseCounts
end

local function worldParts(coverage)
  Assert.equal(type(coverage.worldParts), "function", "the physical coverage must expose resident presentation parts")
  local parts = coverage:worldParts()
  Assert.equal(type(parts), "table", "resident presentation parts must be a table")
  return parts
end

local function partByCell(parts, expectedKey)
  for _, part in ipairs(parts) do
    if part.cellKey == expectedKey then
      return part
    end
  end
  return nil
end

local function regionCellByKey(region, expectedKey)
  for _, cell in ipairs(region.cells) do
    if cell.key == expectedKey then
      return cell
    end
  end
  return nil
end

function T.resident_parts_include_valid_adjacent_cells_before_movement()
  local coverage = newCoverage({})
  local parts = worldParts(coverage)
  local status = coverage:status()
  for _, expectedKey in ipairs(status.residentCellKeys) do
    Assert.notNil(partByCell(parts, expectedKey), "every resident cell must have presentation parts")
  end
  coverage:release()
end

function T.render_collision_and_terrain_report_the_same_cell_owner()
  local coverage = newCoverage({})
  local parts = worldParts(coverage)
  for z = 0, 2 do
    for x = 0, 2 do
      local expectedKey = cellKey(x, z)
      local sampled = assert(coverage:probe(x * 32 + 1, z * 32 + 1))
      Assert.equal(sampled.cellKey, expectedKey, "probe must report its physical cell")
      Assert.equal(sampled.collision.cellKey, expectedKey, "collision must retain its physical cell owner")
      local part = assert(partByCell(parts, expectedKey), "rendering must expose the sampled physical cell")
      Assert.equal(part.cellKey, sampled.cellKey, "rendering and collision must share a physical cell")
      Assert.equal(sampled.sourceSurfaceId, 0, "the source surface identity must remain cell-local")
    end
  end
  coverage:release()
end

function T.recentering_preserves_overlap_and_shared_origin_offsets()
  local coverage, loads, releases = newCoverage({})
  coverage:recenter(2, 1)
  local status = coverage:status()
  Assert.equal(status.residentCount, 9)
  Assert.equal(loads[cellKey(1, 1)], 1, "overlap cells must be retained")
  Assert.equal(releases[cellKey(0, 1)] or 0, 0, "departed cells stay ready in the prefetch halo")

  local parts = worldParts(coverage)
  for z = 0, 2 do
    for x = 1, 3 do
      local expectedKey = cellKey(x, z)
      local part = assert(partByCell(parts, expectedKey), "resident cell presentation is missing")
      local regionCell = assert(regionCellByKey(coverage.region, expectedKey), "resident terrain is missing")
      local expectedY = (x + z) * 0.5 - (2 + 1) * 0.5
      Assert.near(part.translation.x, (x - 2) * 32)
      Assert.near(part.translation.y, expectedY)
      Assert.near(part.translation.z, (z - 1) * 32)
      Assert.near(regionCell.offsetTilesX, part.translation.x)
      Assert.near(regionCell.offsetTilesY, part.translation.y)
      Assert.near(regionCell.offsetTilesZ, part.translation.z)
    end
  end
  coverage:recenter(5, 1)
  Assert.equal(releases[cellKey(0, 1)], 1, "cells leave ownership after leaving the prefetch halo")
  coverage:release()
end

function T.resident_resources_remain_bounded_across_repeated_recenters()
  local coverage, loads, releases = newCoverage({ width = 7 })
  local maximum = 0
  for anchorX = 1, 4 do
    coverage:recenter(anchorX, 1)
    local status = coverage:status()
    maximum = math.max(maximum, status.residentCount)
    local parts = worldParts(coverage)
    Assert.equal(#parts, status.residentCount, "presentation ownership must match CPU residency")
    Assert.isTrue(status.residentCount <= 9, "resident physical resources must stay bounded")
  end
  Assert.equal(loads[cellKey(2, 1)], 1, "overlap cells must not be reacquired")
  Assert.equal(releases[cellKey(0, 1)], 1, "each departed cell must be released once")
  Assert.isTrue(maximum <= 9, "the resident window must never exceed nine cells")
  coverage:release()
end

function T.failed_presentation_acquisition_leaves_the_active_world_unchanged()
  local shouldFail = false
  local coverage, _, releases = newCoverage({
    presentationLoader = function(runtime)
      if shouldFail and runtime.x == 4 then
        error("injected presentation acquisition failure")
      end
      return {
        cellKey = runtime.key,
        release = function()
          activeReleaseCounts[runtime.key .. ":presentation"] = (
            activeReleaseCounts[runtime.key .. ":presentation"] or 0
          ) + 1
        end,
      }
    end,
  })
  local before = coverage:status()
  shouldFail = true
  local err = Assert.throws(function()
    coverage:recenter(3, 1)
  end)
  Assert.isTrue(tostring(err):find("presentation acquisition failure", 1, true) ~= nil)
  local after = coverage:status()
  Assert.equal(after.anchorX, before.anchorX, "failed presentation acquisition must preserve the anchor")
  Assert.equal(after.anchorZ, before.anchorZ)
  Assert.deepEqual(after.residentCellKeys, before.residentCellKeys)
  Assert.equal(releases[cellKey(3, 1) .. ":presentation"], 1, "staged presentation must be released")
  coverage:release()
end

function T.probe_maps_stable_source_identity_without_tile_memo_growth()
  local coverage = newCoverage({})
  local sampled = assert(coverage:probe(3 * 32 + 1, 1 * 32 + 1))
  Assert.equal(sampled.cellKey, cellKey(3, 1), "off-window probes must carry a stable cell identity")
  Assert.equal(sampled.sourceSurfaceId, 0, "probes must carry the source-local surface identity")
  coverage:recenter(3, 1)
  Assert.equal(type(coverage.sourceSurface), "function", "the physical window must map source surfaces after commit")
  Assert.equal(coverage:sourceSurface(sampled.cellKey, sampled.sourceSurfaceId), 1)

  for fieldX = 1, 200 do
    local result = assert(coverage:probe(fieldX, 32 + 1))
    Assert.notNil(result.cellKey)
  end
  Assert.equal(coverage:status().probeCount, 0, "probe state must not grow per visited tile")
  coverage:release()
end

function T.matrix_edges_keep_only_valid_resident_cells()
  local coverage = newCoverage({ width = 2, height = 2, anchorX = 0, anchorZ = 0 })
  local status = coverage:status()
  Assert.equal(status.residentCount, 4)
  Assert.deepEqual(status.residentCellKeys, { "0:0", "0:1", "1:0", "1:1" })
  coverage:release()
end

function T.release_is_idempotent_for_cells_and_presentation()
  local coverage, _, releases = newCoverage({
    presentationLoader = function(runtime)
      return {
        cellKey = runtime.key,
        release = function()
          activeReleaseCounts[runtime.key .. ":presentation"] = (
            activeReleaseCounts[runtime.key .. ":presentation"] or 0
          ) + 1
        end,
      }
    end,
  })
  coverage:release()
  coverage:release()
  Assert.equal(releases["1:1"], 1)
  Assert.equal(releases["1:1:presentation"], 1)
end

function T.animations_advance_once_and_stop_after_eviction()
  local updates = {}
  local releaseCounts = {}
  local coverage = newCoverage({
    width = 4,
    loadCell = function(descriptor)
      local key = cellKey(descriptor.x, descriptor.z)
      local runtime = makeRuntimeFactory({}, releaseCounts)(descriptor)
      runtime.presentation = {
        cellKey = key,
        updateAnimated = function()
          updates[key] = (updates[key] or 0) + 1
        end,
        release = function() end,
      }
      return runtime
    end,
  })
  coverage:updateAnimated()
  coverage:recenter(2, 1)
  coverage:updateAnimated()
  Assert.equal(updates["1:1"], 2, "retained animations advance once per world tick")
  Assert.equal(updates["0:1"], 1, "evicted animations do not advance after release")
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
