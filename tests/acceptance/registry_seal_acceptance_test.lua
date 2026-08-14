-- Production-composed registry sealing contract: once FieldScripts finishes
-- loading, the script registry rejects every public install mutation, while
-- the post-load machinery the seal exempts keeps both production boot paths
-- live — the snapshot-restored fingerprint memo (fast path), the background
-- warm-up's per-resource hash stashing and digest publish (warmup path), and
-- on-demand decode of deferred generated scripts during play. The
-- mutation-gate enumeration is unit-owned (registry_lazy_test.lua /
-- composition_test.lua); acceptance pins that sealing does not break either
-- production composition path.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "registry" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

local function assertWarmupSliceUsesTwoMilliseconds(game)
  local scripts = game.runtime.scripts
  local warmup = assert(scripts.warmup, "snapshot miss must expose the production warm-up")
  local registry = assert(scripts.registry, "snapshot miss must expose the production registry")
  local originalCacheScriptHash = registry.cacheScriptHash
  local processed = 0
  registry.cacheScriptHash = function(self, ...)
    processed = processed + 1
    return originalCacheScriptHash(self, ...)
  end

  local ok, err = xpcall(function()
    local before = processed
    game:step()
    local processedThisUpdate = processed - before
    Assert.equal(
      processedThisUpdate,
      2,
      string.format(
        "one snapshot-miss update must consume the 2 ms default warm-up budget; got %d units",
        processedThisUpdate
      )
    )
    Assert.isFalse(warmup:isComplete(), "the first 2 ms slice must leave the real registry warm-up in progress")
  end, debug.traceback)
  rawset(registry, "cacheScriptHash", nil)
  if not ok then
    error(err, 0)
  end
end
local SNAPSHOT_PATH = "data/generated/script/registry.lua"

-- Every public install mutation of a loaded production registry must be
-- rejected: the registry is sealed once load finishes. Each probe uses its
-- own fresh id so one probe's registration can never collide with another's.
local function assertSealedRegistry(registry)
  local probeId = "acceptance.seal.probe"
  local function id(suffix)
    return probeId .. "." .. suffix
  end
  local attempts = {
    {
      "installBase",
      function()
        registry:installBase(id("base"), { id = id("base") }, "generated")
      end,
    },
    {
      "installBaseDeferred",
      function()
        registry:installBaseDeferred(id("deferred"), "generated")
      end,
    },
  }
  for _, attempt in ipairs(attempts) do
    Assert.throws(attempt[2], "registry " .. attempt[1] .. " must be rejected once the registry is sealed")
  end
end

-- A forced snapshot miss boots the warm-up path; one
-- production runtime update uses the bounded 2 ms default slice, then the
-- background pass runs during play and the save finishes it, publishing the
-- same keyed digest the cache build produced. Sealing must exempt exactly this
-- machinery (cacheScriptHash / fingerprint / restoreFingerprint), so the
-- warm-up path survives the seal and the two boot paths agree.
function T.tests.warmup_path_publishes_a_matching_fingerprint()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local cacheFs = CacheFs.forVersion(versionId)
    local originalBytes = cacheFs:read(SNAPSHOT_PATH)
    local original = assert(cacheFs:loadLua(SNAPSHOT_PATH), "derived cache must carry the registry snapshot")
    local game
    local originalClock = os.clock
    local clock = 0
    local ok, err = xpcall(function()
      rawset(os, "clock", function()
        clock = clock + 0.001
        return clock
      end)
      cacheFs:remove(SNAPSHOT_PATH)
      game = harness:boot({ versionId = versionId, map = LAB, save = "fresh" })
      local scripts = game.runtime.scripts
      Assert.isFalse(scripts.registrySnapshotUsed, "a snapshot miss must boot the warm-up path")
      Assert.notNil(scripts.warmup, "a snapshot miss must create the background warm-up")
      assertWarmupSliceUsesTwoMilliseconds(game)
      rawset(os, "clock", originalClock)
      -- Further warm-up slices run during play.
      game:step()
      game:close()
      Assert.isFalse(
        game.saveStatus:find("Save failed:", 1, true) ~= nil,
        "the save that finishes the warm-up must not fail"
      )
      local published = assert(cacheFs:loadLua(SNAPSHOT_PATH), "the warm-up must publish the snapshot")
      Assert.equal(published.key, original.key, "the published snapshot must key the same corpus")
      Assert.equal(published.fingerprint, original.fingerprint, "the warm-up digest must match the cache-build digest")
    end, debug.traceback)
    rawset(os, "clock", originalClock)
    if game then
      local closeOk, closeErr = pcall(function()
        game:close()
      end)
      if ok and not closeOk then
        ok = false
        err = closeErr
      end
    end
    if originalBytes ~= nil then
      pcall(function()
        cacheFs:write(SNAPSHOT_PATH, originalBytes)
      end)
    end
    if not ok then
      error(err, 0)
    end
  end)
end

-- The snapshot-restored fast path stays live under the seal — the
-- restored fingerprint is the digest save validation uses, every public
-- install mutation is rejected, and a real generated script still decodes on
-- demand (the exempted `_load` memoization) and runs to completion through
-- the production composition.
function T.tests.snapshot_restored_fast_path_rejects_post_load_mutation()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local cacheFs = CacheFs.forVersion(versionId)
    local originalBytes = cacheFs:read(SNAPSHOT_PATH)
    local game
    local ok, err = xpcall(function()
      game = harness:boot({ versionId = versionId, map = TOWN, save = "fresh" })
      local scripts = game.runtime.scripts
      Assert.isTrue(scripts.registrySnapshotUsed, "a matching snapshot must restore the fast path")
      local published = assert(cacheFs:loadLua(SNAPSHOT_PATH), "the derived cache must carry the registry snapshot")
      Assert.equal(
        scripts.registry:fingerprint(),
        published.fingerprint,
        "the restored fingerprint must be the digest save validation uses"
      )
      assertSealedRegistry(scripts.registry)
      -- A real generated script decodes through the sealed registry on
      -- first use and runs to completion.
      game:moveTo({ fieldX = 683, fieldZ = 400 })
      game:face("north")
      game:pressAction()
      Assert.equal(game:interaction().scriptId, "new_bark.npc.woman_1")
      local opened = game:advanceUntil("woman script opens its real first message", function(snapshot)
        return snapshot.dialogue.modal
      end, 120)
      Assert.equal(opened.dialogue.messageId, 9)
      local done = game:advanceDialogue()
      Assert.isFalse(done.snapshot.dialogue.modal)
      Assert.isFalse(done.snapshot.fieldLocked)
    end, debug.traceback)
    if game then
      local closeOk, closeErr = pcall(function()
        game:close()
      end)
      if ok and not closeOk then
        ok = false
        err = closeErr
      end
    end
    if originalBytes ~= nil then
      pcall(function()
        cacheFs:write(SNAPSHOT_PATH, originalBytes)
      end)
    end
    if not ok then
      error(err, 0)
    end
  end)
end

return T
