-- Production-composed transition failure flow. A real destination cache read
-- fails at the filesystem host boundary; the runtime must present the
-- resulting pre-commit error as terminal until reset, without changing source
-- map ownership or constructing any GPU resource.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldErrors = require("libs.engine.src.FieldErrors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "transition", "failure" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

-- Keep the generated cache, map loader, and transition composition real while
-- injecting one deterministic failure at the cache filesystem boundary. The
-- backend is replaced only on this runtime, and the new runtime created by
-- reset gets the normal production backend again.
local function failOneCacheRead(game, relativePath)
  local cacheFs = assert(game.runtime.mapLoader.cacheFs)
  local original = assert(cacheFs.backend)
  local target = cacheFs:resolve(relativePath)
  local failed = false
  local backend = {}
  for name, method in pairs(original) do
    backend[name] = method
  end
  backend.read = function(_, path)
    if path == target and not failed then
      failed = true
      return nil, "acceptance injected destination cache read failure"
    end
    return original:read(path)
  end
  cacheFs.backend = backend
end

local function withGame(game, fn)
  local ok, err = xpcall(fn, debug.traceback)
  local renderAttempts = game:renderAttempts()
  game:close()
  if not ok then
    error(err, 0)
  end
  Assert.equal(renderAttempts, 0, "the failure path must stop before GPU rendering")
end

-- A real lab exit whose destination scene read fails must leave the source
-- map protected and the transition coherently aborted, then freeze every
-- later runtime update until the public reset flow boots a usable session.
function T.tests.failed_destination_preparation_is_terminal_until_reset()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({ versionId = versionId, map = LAB, save = "fresh" })
    withGame(game, function()
      local destinationMapId = assert(game.runtime.mapLoader.world.bySymbol[TOWN])
      failOneCacheRead(game, MapAssetCache.mapDir(destinationMapId) .. "/scene.lua")

      game:moveTo({ fieldX = 4, fieldZ = 14 })
      game:move("south")
      game:advanceUntil("destination preparation failure becomes terminal", function()
        return game.runtime.errorText ~= nil
      end, 120)

      local failed = game:snapshot()
      Assert.equal(failed.mapSymbol, LAB, "the source map remains current after preparation fails")
      Assert.equal(failed.transition.phase, "idle", "the transition aborts to its coherent idle phase")
      Assert.equal(game.runtime.transition.error.code, FieldErrors.FIELD_MAP_VISUAL_CACHE_MISSING)
      Assert.isTrue(
        game.runtime.errorText:find("acceptance injected destination cache read failure", 1, true) ~= nil,
        "the presented error keeps the destination preparation failure context"
      )
      Assert.deepEqual(game:ownership().mapProtectedIds, { failed.mapId })

      local errorText = game.runtime.errorText
      local failedTick = failed.tick
      local failedPlayer = {
        fieldX = failed.player.fieldX,
        fieldZ = failed.player.fieldZ,
        worldY = failed.player.worldY,
        facing = failed.player.facing,
        motion = failed.player.motion,
      }
      local later = game:step()
      Assert.equal(later.tick, failedTick, "a terminal runtime does not step the session")
      Assert.deepEqual({
        later.player.fieldX,
        later.player.fieldZ,
        later.player.worldY,
        later.player.facing,
        later.player.motion,
      }, {
        failedPlayer.fieldX,
        failedPlayer.fieldZ,
        failedPlayer.worldY,
        failedPlayer.facing,
        failedPlayer.motion,
      }, "a terminal runtime freezes player state")
      Assert.equal(game.runtime.errorText, errorText, "terminal error presentation is stable")

      game.runtime:reset()
      Assert.isNil(game.runtime.errorText, "reset clears terminal error presentation")
      Assert.notNil(game.runtime.session, "reset boots a usable session")
      Assert.equal(game.runtime.runtimeMap.mapSymbol, LAB)
      local resetTick = game:snapshot().tick
      Assert.equal(game:step().tick, resetTick + 1, "the reset runtime resumes fixed-step updates")
    end)
  end)
end

return T
