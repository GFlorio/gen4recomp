-- A real presentation boot proves that the fresh outdoor world exposes its
-- resident physical cells before movement. The test uses only an in-memory
-- save backend; generated maps and presentation assets remain production data.

local Assert = require("tests.support.Assert")
local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldState = require("game.src.game.FieldState")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local SaveFs = require("libs.storage.src.SaveFs")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function boot(versionId)
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(_, mapIdOrSymbol, options)
    options.saveFs = SaveFs.forVersion(versionId, FakeCache.new())
    return originalNew(versionId, mapIdOrSymbol, options)
  end
  local ok, state = pcall(FieldState.new, versionId, "MAP_NEW_BARK", { resetSave = true })
  FieldRuntime.new = originalNew
  if not ok then
    error(state, 0)
  end
  return state
end

function T.fresh_outdoor_boot_exposes_adjacent_physical_parts(_)
  for _, versionId in ipairs(readyVersions()) do
    local state = boot(versionId)
    local ok, err = xpcall(function()
      local runtime = assert(state.runtime)
      local coverage = assert(runtime.runtimeMap.coverage)
      Assert.equal(
        type(coverage.worldParts),
        "function",
        "fresh outdoor presentation must expose resident physical-cell parts"
      )
      local status = coverage:status()
      local currentHeader = assert(coverage:mapHeaderAt(status.anchorX * 32 + 1, status.anchorZ * 32 + 1))
      local westHeader = assert(coverage:mapHeaderAt((status.anchorX - 1) * 32 + 1, status.anchorZ * 32 + 1))
      Assert.isTrue(westHeader ~= currentHeader, "the adjacent west physical cell must already be Route 29")

      local parts = coverage:worldParts()
      local partKeys = {}
      for _, part in ipairs(parts) do
        partKeys[assert(part.cellKey)] = true
      end
      for _, expectedKey in ipairs(status.residentCellKeys) do
        Assert.isTrue(partKeys[expectedKey] == true, "every resident physical cell must be drawable before entry")
      end

      state:draw()
    end, debug.traceback)
    state:dispose()
    if not ok then
      error(err, 0)
    end
  end
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump", "derived_cache" }
return suite
