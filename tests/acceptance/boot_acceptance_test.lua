-- Production-composed field boot contract. It is ROM-gated because the game
-- must load the normal derived cache, but it stops at the runtime boundary
-- before any presentation or GPU work. App-facing boot decisions and fault
-- injection live in component tests; acceptance proves the real boot itself.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldSpawns = require("data.manifests.field_spawns")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "boot" },
  },
  tests = {},
}

-- BOOT-01/BOOT-02: explicit semantic targets boot through exactly the same
-- production runtime composition, land on their declared spawn, and are idle,
-- controllable, and never render. The spawn position and facing come from the
-- manifest record, so a regression to the historic synthetic origin would trip
-- the position assertions instead of booting silently onto tile (0,0).
function T.tests.production_field_boot_is_idle_controllable_and_never_renders()
  local harness = AcceptanceHarness.new()
  local maps = { "MAP_NEW_BARK_ELMS_LAB_1F", "MAP_NEW_BARK" }
  harness:forEachVersion(function(versionId)
    for _, map in ipairs(maps) do
      local game = harness:boot({
        versionId = versionId,
        map = map,
        save = "fresh",
      })
      local ok, err = xpcall(function()
        local snapshot = game:snapshot()
        local spawn = FieldSpawns[map]
        local expectedX, expectedZ = FieldCoordinates.localToField(game.runtime.runtimeMap, spawn.x, spawn.z)
        Assert.equal(snapshot.versionId, versionId)
        Assert.equal(snapshot.mapSymbol, map)
        Assert.equal(snapshot.player.fieldX, expectedX, map .. " must boot on its declared spawn x")
        Assert.equal(snapshot.player.fieldZ, expectedZ, map .. " must boot on its declared spawn z")
        Assert.equal(snapshot.player.facing, spawn.facing, map .. " must boot facing its declared spawn facing")
        Assert.equal(snapshot.player.motion, "idle")
        Assert.isFalse(snapshot.dialogue.modal)
        Assert.isFalse(snapshot.fieldLocked)

        game:move("north")
        game:advanceUntil("movement completes", function(state)
          return state.player.motion == "idle" and state.player.facing == "north"
        end, 120)
        Assert.equal(game:renderAttempts(), 0, "acceptance runtime must not construct or draw GPU resources")
      end, debug.traceback)
      game:close()
      if not ok then
        error(err, 0)
      end
    end
  end)
end

-- BOOT-03: every bootable map must declare a spawn. A map without one fails to
-- boot loudly (naming the map) instead of synthesizing the historic (0,0)
-- origin. MAP_ROUTE_29 is a real renderable map absent from the spawn
-- manifest; the precondition asserts that absence so the scenario fails
-- loudly here if the manifest ever gains that entry and the scenario must be
-- re-pointed.
function T.tests.map_without_a_declared_spawn_fails_to_boot_loudly()
  local harness = AcceptanceHarness.new()
  local map = "MAP_ROUTE_29"
  assert(FieldSpawns[map] == nil, map .. " gained a spawn entry; re-point this scenario at a map without one")
  harness:forEachVersion(function(versionId)
    local game
    local ok, err = pcall(function()
      game = harness:boot({ versionId = versionId, map = map, save = "fresh" })
    end)
    if ok then
      local snapshot = game:snapshot()
      game:close()
      error(
        string.format(
          "map without a declared spawn booted at the synthetic origin: field (%d,%d) surface %d",
          snapshot.player.fieldX,
          snapshot.player.fieldZ,
          snapshot.player.surfaceId
        ),
        0
      )
    end
    Assert.isTrue(tostring(err):find(map, 1, true) ~= nil, "boot failure must name the map symbol: " .. tostring(err))
  end)
end

return T
