local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MapResolver = require("romdump.src.digest.MapResolver")

local T = {}

local function u8(v)
  return string.char(v % 256)
end
local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

-- Assemble a map-matrix member (same layout MapMatrix.decode consumes).
local function buildMatrix(spec)
  local n = spec.width * spec.height
  local name = spec.name or ""
  local parts = {
    u8(spec.width),
    u8(spec.height),
    u8(spec.hasHeaders and 1 or 0),
    u8(spec.hasAltitudes and 1 or 0),
    u8(#name),
    name,
  }
  if spec.hasHeaders then
    for i = 1, n do
      parts[#parts + 1] = u16((spec.headers and spec.headers[i]) or 0)
    end
  end
  if spec.hasAltitudes then
    for i = 1, n do
      parts[#parts + 1] = u8((spec.altitudes and spec.altitudes[i]) or 0)
    end
  end
  for i = 1, n do
    parts[#parts + 1] = u16((spec.modelIds and spec.modelIds[i]) or 0)
  end
  return table.concat(parts)
end

-- Minimal RomFs stand-in exposing only openNarc("map_matrices").
local function fakeRomFs(membersByMatrixMemberId)
  return {
    openNarc = function(_, alias)
      Assert.equal(alias, "map_matrices")
      return {
        readMember = function(_, id)
          local bytes = membersByMatrixMemberId[id]
          if not bytes then
            return nil, Errors.new("NARC_MEMBER_ID_OUT_OF_RANGE", "no member " .. id)
          end
          return bytes
        end,
      }
    end,
  }
end

local function elmsLabRomFs()
  return fakeRomFs({
    [100] = buildMatrix({
      width = 1,
      height = 1,
      name = "m_labo01_",
      hasHeaders = false,
      hasAltitudes = false,
      modelIds = { 244 },
    }),
  })
end

-- New Bark: 47x17 with header 60 (and land member 0) at cell (21,12).
local function newBarkRomFs(headerCell)
  headerCell = headerCell or { x = 21, z = 12 }
  local width, height = 47, 17
  local headers = {}
  for i = 1, width * height do
    headers[i] = 0
  end
  headers[headerCell.z * width + headerCell.x + 1] = 60
  return fakeRomFs({
    [0] = buildMatrix({
      width = width,
      height = height,
      name = "map",
      hasHeaders = true,
      hasAltitudes = true,
      headers = headers,
    }),
  })
end

function T.resolves_elms_lab()
  local r = assert(MapResolver.resolve(elmsLabRomFs(), "MAP_NEW_BARK_ELMS_LAB_1F"))
  Assert.equal(r.matrixMemberId, 100)
  Assert.equal(r.matrix.width, 1)
  Assert.equal(r.matrix.height, 1)
  Assert.equal(r.matrix.name, "m_labo01_")
  Assert.equal(r.matrixX, 0)
  Assert.equal(r.matrixZ, 0)
  Assert.equal(r.matrixIndex, 0)
  Assert.equal(r.landDataMemberId, 244)
  Assert.equal(r.areaDataMemberId, 25)
  Assert.equal(r.worldOriginX, 0)
  Assert.equal(r.worldOriginZ, 0)
  Assert.equal(r.map.id, 61)
  Assert.equal(r.source.matrixNarc, "map_matrices")
  Assert.equal(r.source.landDataNarc, "land_data")
  Assert.equal(r.source.areaDataNarc, "area_data")
end

function T.resolves_new_bark()
  local r = assert(MapResolver.resolve(newBarkRomFs(), "MAP_NEW_BARK"))
  Assert.equal(r.matrixMemberId, 0)
  Assert.equal(r.matrix.width, 47)
  Assert.equal(r.matrix.height, 17)
  Assert.equal(r.matrix.name, "map")
  Assert.equal(r.matrixX, 21)
  Assert.equal(r.matrixZ, 12)
  Assert.equal(r.matrixIndex, 585)
  Assert.equal(r.landDataMemberId, 0)
  Assert.equal(r.areaDataMemberId, 2)
  Assert.equal(r.worldOriginX, 672)
  Assert.equal(r.worldOriginZ, 384)
end

function T.resolves_by_numeric_id()
  local r = assert(MapResolver.resolve(elmsLabRomFs(), 61))
  Assert.equal(r.map.symbol, "MAP_NEW_BARK_ELMS_LAB_1F")
end

function T.resolves_multi_cell_map_at_matching_region_centroid()
  local width, height = 3, 1
  local rom = fakeRomFs({
    [0] = buildMatrix({
      width = width,
      height = height,
      hasHeaders = true,
      headers = { 31, 31, 31 },
      modelIds = { 10, 11, 12 },
    }),
  })
  local r = assert(MapResolver.resolve(rom, "MAP_ROUTE_27"))
  Assert.equal(r.matrixX, 1)
  Assert.equal(r.matrixZ, 0)
  Assert.equal(r.landDataMemberId, 11)
end

function T.rejects_non_renderable_catalog_header()
  local rom = fakeRomFs({
    [0] = buildMatrix({
      width = 1,
      height = 1,
      hasHeaders = true,
      headers = { 0 },
      modelIds = { 10 },
    }),
  })
  local r, err = MapResolver.resolve(rom, "MAP_EVERYWHERE")
  Assert.isNil(r)
  Assert.equal(assert(err).code, "MAP_RESOLVE_NOT_RENDERABLE")
end

function T.fails_on_unknown_map()
  local r, err = MapResolver.resolve(elmsLabRomFs(), "MAP_NOPE")
  Assert.isNil(r)
  Assert.equal(assert(err).code, "MAP_CATALOG_UNKNOWN")
end

return { tests = T }
