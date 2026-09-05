-- Pure plane sampling, containment, overlap, and edge-connectivity behavior.

local Assert = require("tests.support.Assert")
local TerrainFixture = require("tests.support.TerrainFixture")
local TerrainSurface = require("libs.hgss.src.world.TerrainSurface")
local SurfaceResolver = require("libs.hgss.src.world.SurfaceResolver")

local T = {}

local function near(actual, expected, epsilon)
  Assert.isTrue(
    math.abs(actual - expected) <= (epsilon or 1e-6),
    string.format("expected %.9f, got %.9f", expected, actual)
  )
end

local function terrain(opts)
  return TerrainSurface.new(TerrainFixture.build(opts))
end

function T.samples_flat_and_four_direction_ramps()
  local t = terrain({
    points = { { x = -16, z = -16 }, { x = 16, z = 16 } },
    slopes = {
      { nx = 0, ny = 4096, nz = 0 },
      { nx = 2896, ny = 2896, nz = 0 },
      { nx = -2896, ny = 2896, nz = 0 },
      { nx = 0, ny = 2896, nz = 2896 },
      { nx = 0, ny = 2896, nz = -2896 },
    },
    heights = { TerrainFixture.heightRaw(0), TerrainFixture.heightRaw(math.sqrt(0.5) * 16) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 1, heightIndex = 1 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 2, heightIndex = 1 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 3, heightIndex = 1 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 4, heightIndex = 1 },
    },
  })
  near(t:sampleHeight(0, 7, 9), 0)
  near(t:sampleHeight(1, 7, 9), 25, 2e-5)
  near(t:sampleHeight(2, 7, 9), 7, 2e-5)
  near(t:sampleHeight(3, 7, 9), 23, 2e-5)
  near(t:sampleHeight(4, 7, 9), 9, 2e-5)
end

function T.candidates_use_local_edge_coordinates_and_include_boundaries()
  local t = terrain({ points = { { x = -2, z = -1 }, { x = 2, z = 3 } } })
  Assert.equal(#t:candidatesAt(14, 15), 1)
  Assert.equal(#t:candidatesAt(18, 19), 1)
  Assert.equal(#t:candidatesAt(13.999, 15), 0)
  Assert.equal(#t:candidatesAt(18.001, 19), 0)
end

function T.candidates_exclude_nonwalkable_sentinel_plates()
  local t = terrain({
    points = { { x = -1, z = 0 }, { x = 1, z = 0 } },
    slopes = { { nx = 0, ny = 0, nz = 4096 } },
  })
  Assert.equal(#t:candidatesAt(16, 16), 0)
end

function T.resolver_keeps_current_surface_through_an_overlap()
  local t = terrain({
    heights = { TerrainFixture.heightRaw(0), TerrainFixture.heightRaw(5) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 1 },
    },
  })
  local resolver = SurfaceResolver.new(t)
  local sample = resolver:resolve({
    localX = 6.5,
    localZ = 6.5,
    currentSurfaceId = 1,
    currentY = 5,
    crossing = { fromX = 5.5, fromZ = 6.5, toX = 6.5, toZ = 6.5 },
  })
  Assert.equal(sample.surfaceId, 1)
  near(sample.worldY, 5)
end

function T.resolver_connects_joined_edges_and_rejects_height_jumps()
  local joined = terrain({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { TerrainFixture.heightRaw(0) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 0 },
    },
  })
  local sample = SurfaceResolver.new(joined):resolve({
    localX = 16.5,
    localZ = 8.5,
    currentSurfaceId = 0,
    currentY = 0,
    crossing = { fromX = 15.5, fromZ = 8.5, toX = 16.5, toZ = 8.5 },
  })
  Assert.equal(sample.surfaceId, 1)

  local jumped = terrain({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { TerrainFixture.heightRaw(0), TerrainFixture.heightRaw(2) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 1 },
    },
  })
  local err = Assert.throws(function()
    SurfaceResolver.new(jumped):resolve({
      localX = 16.5,
      localZ = 8.5,
      currentSurfaceId = 0,
      currentY = 0,
      crossing = { fromX = 15.5, fromZ = 8.5, toX = 16.5, toZ = 8.5 },
    })
  end)
  Assert.equal(err.code, "TERRAIN_SURFACE_DISCONNECTED")
  Assert.equal(err.context.kind, "step-beyond")
end

function T.resolver_crosses_seams_within_the_step_height_limit()
  -- Real ROM floors carry quantized-height seams: adjacent plates whose
  -- planes differ by a small fraction of a tile (MAP_NEW_BARK_PLAYER_HOUSE_1F
  -- has a 0.0014-tile seam). The original movement collision rejects only
  -- steps changing height by >= 1.25 tiles, so such seams must be crossable
  -- in both directions.
  local seamed = terrain({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { TerrainFixture.heightRaw(0), TerrainFixture.heightRaw(0.0014) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 1 },
    },
  })
  local resolver = SurfaceResolver.new(seamed)
  local east = resolver:resolve({
    localX = 16.5,
    localZ = 8.5,
    currentSurfaceId = 0,
    currentY = 0,
    crossing = { fromX = 15.5, fromZ = 8.5, toX = 16.5, toZ = 8.5 },
  })
  Assert.equal(east.surfaceId, 1)
  local west = resolver:resolve({
    localX = 15.5,
    localZ = 8.5,
    currentSurfaceId = 1,
    currentY = 0.0014,
    crossing = { fromX = 16.5, fromZ = 8.5, toX = 15.5, toZ = 8.5 },
  })
  Assert.equal(west.surfaceId, 0)
end

function T.resolver_rejects_a_step_at_the_height_limit()
  -- 1.25 tiles is the original's rejection threshold (5 << 14 in 16.16 tile
  -- units): a step of exactly that height is not a walkable seam.
  local limit = terrain({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { TerrainFixture.heightRaw(0), TerrainFixture.heightRaw(1.25) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 1 },
    },
  })
  local err = Assert.throws(function()
    SurfaceResolver.new(limit):resolve({
      localX = 16.5,
      localZ = 8.5,
      currentSurfaceId = 0,
      currentY = 0,
      crossing = { fromX = 15.5, fromZ = 8.5, toX = 16.5, toZ = 8.5 },
    })
  end)
  Assert.equal(err.code, "TERRAIN_SURFACE_DISCONNECTED")
  Assert.equal(err.context.kind, "step-beyond")
end

function T.current_surface_disconnected_from_the_crossing_is_a_distinct_kind()
  -- The player's own surface does not cover the crossing source: an
  -- inconsistent current terrain state, discriminated from an ordinary
  -- step-height rejection so movement/interaction can propagate it.
  local t = terrain({
    points = {
      { x = -16, z = -16 },
      { x = 0, z = 16 },
      { x = 0, z = -16 },
      { x = 16, z = 16 },
    },
    heights = { TerrainFixture.heightRaw(0) },
    plates = {
      { minPointIndex = 0, maxPointIndex = 1, slopeIndex = 0, heightIndex = 0 },
      { minPointIndex = 2, maxPointIndex = 3, slopeIndex = 0, heightIndex = 0 },
    },
  })
  local err = Assert.throws(function()
    SurfaceResolver.new(t):resolve({
      localX = 16.5,
      localZ = 8.5,
      currentSurfaceId = 0,
      currentY = 0,
      crossing = { fromX = -16.5, fromZ = 8.5, toX = 16.5, toZ = 8.5 },
    })
  end)
  Assert.equal(err.code, "TERRAIN_SURFACE_DISCONNECTED")
  Assert.equal(err.context.kind, "current-inconsistent")
end

return { tests = T }
