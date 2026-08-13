-- FieldRuntime construction and save-boundary failure contracts. Construction
-- is binary through the production composition: a missing required artifact or
-- a boot-time programming assertion must make FieldRuntime.new fail instead of
-- returning a session-less runtime, cleanup of a partially acquired boot must
-- stay exact-once, and the save boundary must present only expected
-- save/storage failures -- never flatten an unrelated programming fault into
-- the friendly save-failure text. All scenarios boot the real runtime against
-- the real derived cache, so they declare the ROM capabilities.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldRuntime = require("game.src.game.FieldRuntime")
local SaveFs = require("libs.storage.src.SaveFs")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "component",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "boot", "runtime" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local SPAWN_GAP_MAP = "MAP_ROUTE_29"

-- A map that loads from the real derived cache but has no spawn-manifest
-- entry: the boot acquires the map and protects it, then the spawn-manifest
-- assert fires. The precondition keeps this scenario pointed at a real map
-- the manifest genuinely omits.
assert(require("data.manifests.field_spawns")[SPAWN_GAP_MAP] == nil, SPAWN_GAP_MAP .. " gained a spawn entry")

local function removeNamespace(path)
  local fs = love.filesystem
  fs.remove(path .. "/" .. FieldSave.PATH .. ".tmp")
  fs.remove(path .. "/" .. FieldSave.PATH)
  fs.remove(path)
end

-- A save backend whose write raises a plain (non-structured) host fault. The
-- SaveFs contract documents that a raising backend propagates, so this is a
-- reachable host-boundary failure, not an impossible fake.
local function raisingWriteBackend(fault)
  local fs = love.filesystem
  return {
    write = function(_, path, data)
      if fault then
        error("injected save host programming fault")
      end
      return fs.write(path, data)
    end,
    read = function(_, path)
      return fs.read(path)
    end,
    getInfo = function(_, path)
      return fs.getInfo(path)
    end,
    createDirectory = function(_, path)
      return fs.createDirectory(path)
    end,
    remove = function(_, path)
      return fs.remove(path)
    end,
    replace = function(_, sourcePath, destinationPath)
      return os.rename(fs.getSaveDirectory() .. "/" .. sourcePath, fs.getSaveDirectory() .. "/" .. destinationPath)
    end,
  }
end

-- A missing required runtime artifact (here: a version with no compiled
-- cache, so the actor index is absent) must make FieldRuntime.new fail, never
-- return a session-less runtime that downstream guards would have to
-- compensate for.
function T.tests.missing_required_artifact_fails_construction_instead_of_partial_runtime()
  local ok, err = pcall(function()
    FieldRuntime.new("no-such-version")
  end)
  Assert.isFalse(ok, "construction must fail on a missing required artifact")
  Assert.isTrue(
    tostring(err):find("field actor index missing", 1, true) ~= nil,
    "the failure must name the missing artifact: " .. tostring(err)
  )
end

-- A boot that fails after acquiring the map (loaded and protected) must
-- surface loudly and leave the process clean: no save written by the partial
-- boot, no state that breaks the next boot, and exactly one disposal for the
-- successful boot. The map without a spawn is the production-reachable
-- failure point.
function T.tests.failed_boot_releases_acquired_resources_and_leaves_the_next_boot_clean()
  local harness = AcceptanceHarness.new({ versions = { "heartgold" } })
  local err = Assert.throws(function()
    harness:boot({ versionId = "heartgold", map = SPAWN_GAP_MAP, save = "fresh" })
  end)
  Assert.isTrue(
    tostring(err):find(SPAWN_GAP_MAP, 1, true) ~= nil,
    "the failed boot must name the map: " .. tostring(err)
  )

  local game = harness:boot({ versionId = "heartgold", map = LAB, save = "fresh" })
  local ok, stepErr = pcall(function()
    game:step()
  end)
  if not ok then
    game:close()
    error(stepErr, 0)
  end
  game:close()
  Assert.equal(game.lifecycle.runtimeDisposals, 1, "the successful boot is disposed exactly once")
  Assert.equal(game.lifecycle.saveWrites, 1, "only the successful boot's close may write a save")
end

-- A programming assertion inside boot is a plain assert, not an expected
-- runtime failure: it must be rethrown, not stored as runtime error text on a
-- returned object.
function T.tests.programming_assertion_in_boot_is_rethrown_not_stored_as_error_text()
  local ok, err = pcall(function()
    FieldRuntime.new("heartgold", SPAWN_GAP_MAP)
  end)
  Assert.isFalse(ok, "a boot-time programming assertion must rethrow")
  Assert.isTrue(
    tostring(err):find("spawn manifest must define a spawn", 1, true) ~= nil,
    "the rethrown assertion must keep its message: " .. tostring(err)
  )
  Assert.isTrue(
    tostring(err):find(SPAWN_GAP_MAP, 1, true) ~= nil,
    "the rethrown assertion must name the map: " .. tostring(err)
  )
end

-- The save boundary presents expected save/storage failures as a save
-- failure, but a non-structured host fault inside the save path is a
-- programming fault: it must propagate instead of being flattened into the
-- friendly save-failure text.
function T.tests.save_host_programming_fault_is_rethrown_not_reported_as_save_failure()
  local namespace = "component/save-fault/heartgold"
  removeNamespace(namespace)
  local saveFs = SaveFs.forVersion("heartgold", raisingWriteBackend(true), namespace)
  local runtime = FieldRuntime.new("heartgold", LAB, { saveFs = saveFs })
  local ok, err = xpcall(function()
    runtime:dispose()
  end, debug.traceback)
  local raised = not ok
  removeNamespace(namespace)
  if not raised then
    error("a programming fault in the save path must rethrow", 0)
  end
  Assert.isTrue(
    tostring(err):find("injected save host programming fault", 1, true) ~= nil,
    "the raw fault must propagate: " .. tostring(err)
  )
  Assert.isTrue(
    tostring(err):find("Save failed:", 1, true) == nil,
    "a programming fault must not be repackaged as a save failure: " .. tostring(err)
  )
end

return T
