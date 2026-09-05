-- Tests dump-backed map analysis without needing a private ROM. Synthetic
-- decoded matrices cover each selection outcome.

local Assert = require("tests.support.Assert")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")

local T = {}

local function matrix(spec)
  local headers = assert(spec.headers)
  local models = assert(spec.models)
  return {
    width = assert(spec.width),
    height = assert(spec.height),
    hasHeaders = spec.hasHeaders ~= false,
    findCellsByMapHeaderId = function(self, mapId)
      local cells = {}
      for index = 0, #headers - 1 do
        if headers[index + 1] == mapId then
          cells[#cells + 1] = {
            x = index % self.width,
            z = math.floor(index / self.width),
            index = index,
          }
        end
      end
      return cells
    end,
    cell = function(self, x, z)
      local index = z * self.width + x
      return { landDataMemberId = models[index + 1] }
    end,
  }
end

function T.derives_unique_cell_and_land_member()
  local result = MapAnalysis.analyzeRecord(
    { id = 7 },
    matrix({
      width = 2,
      height = 1,
      headers = { 0, 7 },
      models = { 10, 11 },
    })
  )
  Assert.equal(result.status, "resolved")
  Assert.equal(result.matrixX, 1)
  Assert.equal(result.matrixZ, 0)
  Assert.equal(result.landDataMemberId, 11)
end

function T.resolves_headerless_single_cell()
  local result = MapAnalysis.analyzeRecord(
    { id = 8 },
    matrix({
      width = 1,
      height = 1,
      hasHeaders = false,
      headers = { 8 },
      models = { 42 },
    })
  )
  Assert.equal(result.status, "resolved")
  Assert.equal(result.matrixX, 0)
  Assert.equal(result.matrixZ, 0)
  Assert.equal(result.landDataMemberId, 42)
end

function T.excludes_missing_cell_and_selects_multi_cell_region_centroid()
  local missing = MapAnalysis.analyzeRecord(
    { id = 9 },
    matrix({
      width = 1,
      height = 1,
      headers = { 0 },
      models = { 10 },
    })
  )
  Assert.equal(missing.status, "excluded")
  Assert.equal(missing.reason, "no_matching_cell")
  Assert.equal(missing.matchCount, 0)

  local multiCell = MapAnalysis.analyzeRecord(
    { id = 10 },
    matrix({
      width = 3,
      height = 1,
      headers = { 10, 10, 10 },
      models = { 10, 11, 12 },
    })
  )
  Assert.equal(multiCell.status, "resolved")
  Assert.equal(multiCell.source, "matching_region_centroid")
  Assert.equal(multiCell.matrixX, 1)
  Assert.equal(multiCell.matrixZ, 0)
  Assert.equal(multiCell.landDataMemberId, 11)
end

function T.default_header_filler_is_excluded()
  local result = MapAnalysis.analyzeRecord(
    { id = 0 },
    matrix({
      width = 2,
      height = 1,
      headers = { 0, 0 },
      models = { 30, 31 },
    })
  )
  Assert.equal(result.status, "excluded")
  Assert.equal(result.reason, "default_header_filler")
end

function T.excludes_cell_without_land_data()
  local result = MapAnalysis.analyzeRecord(
    { id = 7 },
    matrix({
      width = 1,
      height = 1,
      headers = { 7 },
      models = { 0xFFFF },
    })
  )
  Assert.equal(result.status, "excluded")
  Assert.equal(result.reason, "no_land_data")
  Assert.equal(result.matchCount, 1)
end

return { tests = T }
