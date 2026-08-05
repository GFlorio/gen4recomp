-- MapCacheWriter: a successful write leaves a ready map with the marker last; an
-- injected write failure leaves no completion marker and rolls back the map
-- subtree without disturbing the raw-dump marker.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local MapCacheWriter = require("romdump.src.digest.MapCacheWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Bundle = require("tests.support.BundleFixture")

local T = {}

-- Wrap a FakeCache backend so writes to a path substring raise.
local function failOn(backend, substr)
  local orig = backend.write
  backend.write = function(self, path, data)
    if path:find(substr, 1, true) then error("injected write failure") end
    return orig(self, path, data)
  end
  return backend
end

function T.writes_marker_last_and_is_ready()
  local c = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = Bundle.minimal()
  local marker = MapCacheWriter.write(c, bundle)
  Assert.equal(marker, bundle.marker)
  Assert.isTrue(MapAssetCache.isReady(c, bundle.mapId, marker), "ready after write")
end

function T.injected_failure_leaves_no_marker()
  local backend = failOn(FakeCache.new(), "scene.lua")
  local c = CacheFs.forVersion("heartgold", backend)
  local bundle = Bundle.minimal()
  Assert.isTrue(not pcall(MapCacheWriter.write, c, bundle), "write raises")
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(bundle.mapId) .. "/complete"), "no false marker")
  -- Rolled back: the map's permission grid is gone too.
  Assert.isTrue(not c:exists(MapAssetCache.mapDir(bundle.mapId) .. "/permissions.bin"), "map subtree rolled back")
end

function T.failure_preserves_raw_dump_marker()
  local backend = failOn(FakeCache.new(), "scene.lua")
  local c = CacheFs.forVersion("heartgold", backend)
  c:write("rom-dump.complete", "raw")
  pcall(MapCacheWriter.write, c, Bundle.minimal())
  Assert.isTrue(c:exists("rom-dump.complete"), "raw marker untouched")
end

return T
