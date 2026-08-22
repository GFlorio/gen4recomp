-- Production-composed field boot contract. It is ROM-gated because the game
-- must load the normal derived cache, but it stops at the runtime boundary
-- before any presentation or GPU work. App-facing boot decisions and fault
-- injection live in component tests; acceptance proves the real boot itself.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "boot" },
  },
  tests = {},
}

local BOOT_LOCATIONS = {
  MAP_NEW_BARK_ELMS_LAB_1F = { fieldX = 4, fieldZ = 13, facing = "north" },
  MAP_NEW_BARK = { fieldX = 12, fieldZ = 10, facing = "south" },
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
        local location = BOOT_LOCATIONS[map]
        Assert.equal(snapshot.versionId, versionId)
        Assert.equal(snapshot.mapSymbol, map)
        Assert.equal(snapshot.player.fieldX, location.fieldX, map .. " must boot at its supplied x")
        Assert.equal(snapshot.player.fieldZ, location.fieldZ, map .. " must boot at its supplied z")
        Assert.equal(snapshot.player.facing, location.facing, map .. " must boot at its supplied facing")
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

return T
