-- Coverage tests use CPU-only cell runtimes and count ownership transitions.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.engine.src.FieldCoverage")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

---@class PhysicalProbeCoverage
---@field probe fun(self: PhysicalProbeCoverage, fieldX: integer, fieldZ: integer, context: PhysicalProbeContext): table?

local function makeIndex()
  local cells = {}
  for z = 0, 2 do
    for x = 0, 4 do
      local index = z * 5 + x
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        origin = { x = x * 32, y = ((x + z) % 2) * 0.5, z = z * 32 },
        mapHeaderId = 60,
        altitude = (x + z) % 2,
        landDataMemberId = 1,
        areaDataMemberId = 1,
        file = "cell/" .. index,
      }
    end
  end
  return {
    schema = "g4-field-cell-index-v2",
    matrices = { { matrixMemberId = 1, width = 5, height = 3, cells = cells } },
  }
end

local function runtimeFactory(releases)
  return function(descriptor)
    local plates = {
      {
        id = 0,
        minX = 0,
        maxX = 32,
        minZ = 0,
        maxZ = 32,
        normal = { x = 0, y = 1, z = 0 },
        distance = descriptor.altitude * 0.5,
      },
    }
    return {
      key = string.format("%d:%d", descriptor.x, descriptor.z),
      x = descriptor.x,
      z = descriptor.z,
      altitude = descriptor.altitude,
      collision = {
        containsLocal = function(_, x, z)
          return x >= 0 and x < 32 and z >= 0 and z < 32
        end,
        isBlockedLocal = function()
          return false
        end,
        getLocal = function()
          return { blocked = false }
        end,
      },
      terrain = { plates = plates, artifact = { source = { bdhcSha1 = descriptor.file } } },
      release = function()
        releases[descriptor.x .. ":" .. descriptor.z] = (releases[descriptor.x .. ":" .. descriptor.z] or 0) + 1
      end,
    }
  end
end

function T.recenters_reusing_overlap_and_releases_departures()
  local releases = {}
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = runtimeFactory(releases),
  })
  Assert.equal(coverage:status().residentCount, 9)
  coverage:recenter(2, 1)
  local status = coverage:status()
  Assert.equal(status.residentCount, 9)
  Assert.equal(releases["0:0"], 1)
  Assert.equal(releases["0:1"], 1)
  Assert.equal(releases["0:2"], 1)
  coverage:release()
  Assert.equal(releases["1:1"], 1)
end

function T.failed_acquisition_keeps_active_anchor()
  local fail = false
  local coverage = FieldCoverage.new({
    matrixMemberId = 1,
    index = makeIndex(),
    anchorX = 1,
    anchorZ = 1,
    loadCell = function(descriptor)
      if fail and descriptor.x == 3 then
        error("injected acquisition failure")
      end
      return runtimeFactory({})(descriptor)
    end,
  })
  fail = true
  Assert.throws(function()
    coverage:recenter(3, 1)
  end)
  Assert.equal(coverage:status().anchorX, 1)
  Assert.equal(coverage:status().anchorZ, 1)
end

local function adjacentIndex(reverse)
  local destinationPlates = {
    {
      id = 10,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
    },
    {
      id = 11,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
    },
  }
  if reverse then
    destinationPlates[1], destinationPlates[2] = destinationPlates[2], destinationPlates[1]
  end
  return {
    schema = "g4-field-cell-index-v2",
    matrices = {
      {
        matrixMemberId = 1,
        width = 2,
        height = 1,
        cells = {
          { matrixMemberId = 1, index = 0, x = 0, z = 0, origin = { x = 0, y = 0, z = 0 } },
          { matrixMemberId = 1, index = 1, x = 1, z = 0, origin = { x = 32, y = 0, z = 0 } },
        },
      },
    },
  },
    destinationPlates
end

local function adjacentCoverage(reverse, plates)
  local index, destinationPlates = adjacentIndex(reverse)
  destinationPlates = plates or destinationPlates
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = index,
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      local cellPlates = descriptor.x == 1 and destinationPlates
        or {
          {
            id = 0,
            minX = 0,
            minZ = 0,
            maxX = 32,
            maxZ = 32,
            normal = { x = 0, y = 1, z = 0 },
            distance = 0,
          },
        }
      return {
        key = string.format("%d:%d", descriptor.x, descriptor.z),
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function(_, x, z)
            return x >= 0 and x < 32 and z >= 0 and z < 32
          end,
          getLocal = function()
            return { blocked = false }
          end,
        },
        terrain = TerrainSurface.new({ plates = cellPlates }),
        release = function() end,
      }
    end,
  })
end

function T.destination_resolution_uses_continuity_not_source_order()
  local function resolve(reverse)
    local coverage = adjacentCoverage(reverse)
    local probeCoverage = coverage --[[@as PhysicalProbeCoverage]]
    local result = probeCoverage:probe(32, 0, {
      currentCellKey = "0:0",
      currentSourceSurfaceId = 0,
      currentY = 0,
      fromFieldX = 31,
      fromFieldZ = 0,
    })
    coverage:release()
    return result
  end

  local forward = assert(resolve(false))
  local reversed = assert(resolve(true))
  Assert.equal(forward.sourceSurfaceId, 11)
  Assert.equal(reversed.sourceSurfaceId, 11)
  Assert.equal(forward.worldY, 0)
  Assert.equal(reversed.worldY, 0)

  local blocked = adjacentCoverage(false, {
    {
      id = 12,
      minX = 0,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
    },
  })
  local probeCoverage = blocked --[[@as PhysicalProbeCoverage]]
  Assert.isNil(probeCoverage:probe(32, 0, {
    currentCellKey = "0:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 31,
    fromFieldZ = 0,
  }))
  blocked:release()
end

local function temporaryProbeCoverage(destinationX, destinationDistance, releases)
  local cells = {}
  for x = 0, destinationX do
    cells[#cells + 1] = {
      matrixMemberId = 1,
      index = x,
      x = x,
      z = 0,
      origin = { x = x * 32, y = 0, z = 0 },
    }
  end
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = {
      schema = "g4-field-cell-index-v2",
      matrices = { { matrixMemberId = 1, width = destinationX + 1, height = 1, cells = cells } },
    },
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      local cellKey = string.format("%d:%d", descriptor.x, descriptor.z)
      return {
        key = cellKey,
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function(_, x, z)
            return x >= 0 and x < 32 and z >= 0 and z < 32
          end,
          getLocal = function()
            return { blocked = false }
          end,
        },
        terrain = TerrainSurface.new({
          plates = {
            {
              id = 0,
              minX = 0,
              minZ = 0,
              maxX = 32,
              maxZ = 32,
              normal = { x = 0, y = 1, z = 0 },
              distance = descriptor.x == destinationX and destinationDistance or 0,
            },
          },
        }),
        release = function()
          releases[cellKey] = (releases[cellKey] or 0) + 1
        end,
      }
    end,
  })
end

function T.temporary_probe_releases_its_cell_on_success_and_rejection()
  local releases = {}
  local coverage = temporaryProbeCoverage(2, 0, releases)
  local result = coverage:probe(64, 0, {
    currentCellKey = "1:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 63,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(2, 2, releases)
  Assert.isNil(coverage:probe(64, 0, {
    currentCellKey = "1:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 63,
    fromFieldZ = 0,
  }))
  Assert.equal(releases["2:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(3, 0, releases)
  result = coverage:probe(96, 0, {
    currentCellKey = "2:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 95,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  Assert.equal(releases["3:0"], 1)
  coverage:release()

  releases = {}
  coverage = temporaryProbeCoverage(2, 0, releases)
  result = coverage:probe(65, 0, {
    currentCellKey = "2:0",
    currentSourceSurfaceId = 0,
    currentY = 0,
    fromFieldX = 64,
    fromFieldZ = 0,
  })
  Assert.equal(assert(result).sourceSurfaceId, 0)
  Assert.equal(releases["2:0"], 1)
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
