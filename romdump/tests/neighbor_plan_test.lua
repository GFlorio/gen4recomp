-- Pure tests for NeighborPlan.plan: matrix-driven neighbor selection, exact
-- 32-tile offsets, land-member dedup, out-of-bounds skipping without wrapping,
-- and skipping cells whose header has no area mapping. No ROM, no love.

local Assert = require("tests.support.Assert")
local MapMatrix = require("libs.assets.src.MapMatrix")
local NeighborPlan = require("romdump.src.digest.NeighborPlan")

local T = {}

local function u8(v)
  return string.char(v % 256)
end
local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

-- Assemble a 5x5 matrix member with explicit header/land grids (row-major,
-- index = z*5 + x + 1).
local function build(headers, landIds)
  local parts = { u8(5), u8(5), u8(1), u8(0), u8(0) }
  for i = 1, 25 do
    parts[#parts + 1] = u16(headers[i])
  end
  for i = 1, 25 do
    parts[#parts + 1] = u16(landIds[i])
  end
  return table.concat(parts)
end

local function idx(x, z)
  return z * 5 + x + 1
end

-- Area resolver mirroring the checked-in New Bark neighbor mapping.
local function areaForHeader(h)
  return ({ [0] = 0, [31] = 2, [33] = 2 })[h]
end

-- A 5x5 matrix centred on (2,2): eight neighbours with a mix of mapped headers,
-- one unmapped header (skipped), and a land member shared by three cells.
local function sampleMatrix()
  local headers, land = {}, {}
  for i = 1, 25 do
    headers[i] = 7
    land[i] = 999
  end -- 7 is unmapped; non-neighbours are irrelevant
  headers[idx(2, 2)] = 60
  land[idx(2, 2)] = 0 -- centre
  headers[idx(1, 1)] = 0
  land[idx(1, 1)] = 208
  headers[idx(2, 1)] = 0
  land[idx(2, 1)] = 208 -- shares 208
  headers[idx(3, 1)] = 99
  land[idx(3, 1)] = 500 -- unmapped header -> skipped
  headers[idx(1, 2)] = 33
  land[idx(1, 2)] = 3
  headers[idx(3, 2)] = 31
  land[idx(3, 2)] = 11
  headers[idx(1, 3)] = 0
  land[idx(1, 3)] = 208 -- shares 208
  headers[idx(2, 3)] = 0
  land[idx(2, 3)] = 209
  headers[idx(3, 3)] = 0
  land[idx(3, 3)] = 210
  return assert(MapMatrix.decode(build(headers, land)))
end

local function cellAt(plan, x, z)
  for _, c in ipairs(plan.cells) do
    if c.x == x and c.z == z then
      return c
    end
  end
  return nil
end

function T.selects_mapped_neighbors_and_skips_unmapped()
  local plan = NeighborPlan.plan(sampleMatrix(), 2, 2, areaForHeader)
  -- Seven of the eight neighbours are kept; (3,1)'s header 99 has no mapping.
  Assert.equal(#plan.cells, 7)
  Assert.isNil(cellAt(plan, 3, 1))
  local w = assert(cellAt(plan, 1, 2))
  Assert.equal(w.mapHeaderId, 33)
  Assert.equal(w.landDataMemberId, 3)
  Assert.equal(w.areaDataMemberId, 2)
end

function T.offsets_are_exactly_32_tiles()
  local plan = NeighborPlan.plan(sampleMatrix(), 2, 2, areaForHeader)
  local e = assert(cellAt(plan, 3, 2)) -- east: dx=+1, dz=0
  Assert.equal(e.offsetTilesX, 32)
  Assert.equal(e.offsetTilesZ, 0)
  local nw = assert(cellAt(plan, 1, 1)) -- north-west: dx=-1, dz=-1
  Assert.equal(nw.offsetTilesX, -32)
  Assert.equal(nw.offsetTilesZ, -32)
end

function T.dedups_shared_land_members()
  local plan = NeighborPlan.plan(sampleMatrix(), 2, 2, areaForHeader)
  -- Land 208 is used by three cells but appears once in the unique set.
  Assert.deepEqual(plan.uniqueLandMembers, { 3, 11, 208, 209, 210 })
end

function T.skips_out_of_bounds_without_wrapping()
  -- Centre at the corner (0,0): only (1,0), (0,1), (1,1) are in bounds; the five
  -- negative-coordinate neighbours are dropped, never wrapped to the far edge.
  local plan = NeighborPlan.plan(sampleMatrix(), 0, 0, areaForHeader)
  for _, c in ipairs(plan.cells) do
    Assert.isTrue(c.x >= 0 and c.x <= 1 and c.z >= 0 and c.z <= 1, "no wrapped cell; got (" .. c.x .. "," .. c.z .. ")")
  end
  -- Only (1,1) has a mapped header among the three in-bounds neighbours.
  Assert.equal(#plan.cells, 1)
  local c = assert(cellAt(plan, 1, 1))
  Assert.equal(c.offsetTilesX, 32)
  Assert.equal(c.offsetTilesZ, 32)
end

function T.skips_neighbors_without_land_data()
  local matrix = sampleMatrix()
  matrix.modelIds[idx(1, 1)] = 0xFFFF
  local plan = NeighborPlan.plan(matrix, 2, 2, areaForHeader)
  Assert.isNil(cellAt(plan, 1, 1))
  Assert.deepEqual(plan.uniqueLandMembers, { 3, 11, 208, 209, 210 })
end

return T
