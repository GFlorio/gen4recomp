-- Coverage tests use CPU-only cell runtimes and count ownership transitions.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.engine.src.FieldCoverage")

local T = {}

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

return { metadata = { capabilities = {} }, tests = T }
