-- Field coordinate tests prove the single conversion boundary between event/
-- save coordinates, the loaded permission cell, and centered render space.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")

local T = {}

local function runtimeMap()
  return {
    coordinateOrigin = { x = 672, z = 384 },
    permissions = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
  }
end

function T.round_trips_field_and_local_coordinates()
  local map = runtimeMap()
  local x, z = FieldCoordinates.fieldToLocal(map, 684, 393)
  Assert.equal(x, 12)
  Assert.equal(z, 9)
  Assert.deepEqual({ FieldCoordinates.localToField(map, x, z) }, { 684, 393 })
end

function T.converts_tile_centres_to_centered_render_space()
  local point = FieldCoordinates.fieldToWorld(runtimeMap(), 684, 393, 2.5)
  Assert.deepEqual(point, { x = -3.5, y = 2.5, z = -6.5 })
end

function T.rejects_coordinates_outside_loaded_permission_coverage()
  local err = Assert.throws(function()
    FieldCoordinates.fieldToLocal(runtimeMap(), 704, 393)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FIELD_COORDINATES_OUT_OF_COVERAGE")
  Assert.equal(err.context.fieldX, 704)
end

return T
