-- The provisional field spawn manifest contract: every entry is itself the
-- spawn record, flat (x, z, facing) -- the shape FieldState consumes. A
-- nested `spawn` wrapper regressed silently into the (0,0) fallback before,
-- so the flat shape is pinned here.

local Assert = require("tests.support.Assert")
local FieldSpawns = require("data.manifests.field_spawns")

local T = {}

local FACING = { north = true, south = true, west = true, east = true }

function T.entries_are_flat_spawn_records()
  assert(next(FieldSpawns) ~= nil, "spawn manifest is empty")
  for symbol, spawn in pairs(FieldSpawns) do
    Assert.isTrue(type(spawn.x) == "number" and type(spawn.z) == "number", symbol .. " must define numeric x and z")
    Assert.isTrue(FACING[spawn.facing] == true, symbol .. " must define a valid facing")
    Assert.isNil(spawn.spawn, symbol .. " must not nest under a spawn key")
  end
end

function T.target_maps_have_spawns()
  Assert.notNil(FieldSpawns.MAP_NEW_BARK_ELMS_LAB_1F, "Elm's Lab spawn missing")
  Assert.notNil(FieldSpawns.MAP_NEW_BARK, "New Bark spawn missing")
end

return T
