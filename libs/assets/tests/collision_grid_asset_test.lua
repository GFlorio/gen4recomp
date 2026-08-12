-- Tests for CollisionGridAsset: the project-owned G4CL collision binary format.
-- encode/decode round trip, exact dimensions, blocked semantics, behavior and
-- terrain-response ids, and rejection of malformed magic/version/size/boolean
-- bytes. No HGSS packing knowledge belongs here or in the engine.

local Assert = require("tests.support.Assert")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")

local T = {}

local function decodeErr(bytes)
  local grid, err = CollisionGridAsset.decode(bytes)
  Assert.isNil(grid)
  Assert.notNil(err)
  return assert(err)
end

-- A grid of the given dimensions; the block flag at (1,1) is set to `blocked`.
local function grid(width, height, blocked)
  local cells = {}
  for index = 1, width * height do
    cells[index] = { behavior = 0, terrainResponseId = 0, blocked = false }
  end
  cells[1 * width + 2] = { behavior = blocked and 3 or 0, terrainResponseId = 6, blocked = blocked }
  return { width = width, height = height, cells = cells }
end

function T.encode_decode_round_trips_an_exact_grid()
  local g = grid(32, 32, true)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.equal(decoded.width, 32)
  Assert.equal(decoded.height, 32)
  Assert.equal(#decoded.cells, 1024)
  Assert.equal(decoded.cells[1 * 32 + 2].behavior, 3)
  Assert.equal(decoded.cells[1 * 32 + 2].terrainResponseId, 6)
  Assert.isTrue(decoded.cells[1 * 32 + 2].blocked)
  Assert.isFalse(decoded.cells[0 * 32 + 1].blocked)
end

function T.small_grids_keep_exact_dimensions()
  local g = grid(2, 3, false)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.equal(decoded.width, 2)
  Assert.equal(decoded.height, 3)
  Assert.equal(#decoded.cells, 6)
end

function T.passable_cells_round_trip_as_unblocked()
  local g = grid(4, 4, false)
  local decoded = assert(CollisionGridAsset.decode(CollisionGridAsset.encode(g)))
  Assert.isFalse(decoded.cells[1 * 4 + 2].blocked)
end

-- A structurally valid G4CL asset with the given version/dimensions and zero
-- cells; the caller then corrupts the field under test.
local function asset(version, width, height)
  local cells = string.rep(string.char(0, 0, 0), width * height)
  return "G4CL"
    .. string.char(version % 256, math.floor(version / 256))
    .. string.char(width % 256, math.floor(width / 256))
    .. string.char(height % 256, math.floor(height / 256))
    .. cells
end

function T.rejects_bad_magic()
  Assert.equal(decodeErr("G4CM" .. asset(1, 4, 4):sub(5)).code, "COLLISION_BAD_MAGIC")
end

function T.rejects_unsupported_version()
  Assert.equal(decodeErr(asset(2, 4, 4)).code, "COLLISION_BAD_VERSION")
end

function T.rejects_zero_dimensions()
  Assert.equal(decodeErr(asset(1, 0, 4)).code, "COLLISION_BAD_DIMENSIONS")
  Assert.equal(decodeErr(asset(1, 4, 0)).code, "COLLISION_BAD_DIMENSIONS")
end

function T.rejects_wrong_total_byte_length()
  local g = grid(2, 2, false)
  local bytes = CollisionGridAsset.encode(g)
  Assert.equal(decodeErr(bytes:sub(1, #bytes - 1)).code, "COLLISION_BAD_SIZE")
  Assert.equal(decodeErr(bytes .. "\0").code, "COLLISION_BAD_SIZE")
end

function T.rejects_blocked_bytes_other_than_zero_or_one()
  local bytes = asset(1, 2, 2)
  local corrupted = bytes:sub(1, 10) .. string.char(0, 0, 2) .. bytes:sub(14)
  Assert.equal(decodeErr(corrupted).code, "COLLISION_BAD_BLOCKED")
end

function T.rejects_a_header_shorter_than_the_format_prefix()
  Assert.equal(decodeErr("G4C").code, "COLLISION_BAD_SIZE")
end

function T.encode_rejects_malformed_grids()
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 2, height = 2, cells = { { blocked = false } } })
  end)
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 2, height = 2, cells = {} })
  end)
  Assert.throws(function()
    CollisionGridAsset.encode({ width = 0, height = 2, cells = {} })
  end)
  Assert.throws(function()
    local g = grid(1, 1, false)
    g.cells[1].blocked = 1
    CollisionGridAsset.encode(g)
  end)
  Assert.throws(function()
    local g = grid(1, 1, false)
    g.cells[1].behavior = 256
    CollisionGridAsset.encode(g)
  end)
end

return T
