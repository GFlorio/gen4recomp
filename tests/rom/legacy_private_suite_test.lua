-- The legacy real-dump modules under `tests/private/`, run as one ROM-layer
-- suite of the single runner. They take `(romFs, versionId)` instead of a
-- runner context, so this module adapts them rather than being discovered
-- directly: the modules are enumerated by the same recursive discovery the
-- runner uses (no registry), and every function runs against every ready
-- version.
--
-- This bridge and its support file go away once those modules are rewritten as
-- ordinary suites under `tests/rom/`.

local Capabilities = require("tests.runner.Capabilities")
local Discovery = require("tests.runner.Discovery")
local LegacyRomSuite = require("tests.rom.support.LegacyRomSuite")
local RepoFiles = require("tests.runner.RepoFiles")

local RomFs = require("libs.rom.src.RomFs")

local LEGACY_ROOT = { path = "tests/private", prefix = "tests.private", layer = "rom" }

local function legacyModules()
  local fs = RepoFiles.new(love.filesystem.getSourceBaseDirectory(), { LEGACY_ROOT.path })
  local modules = {}
  for _, entry in ipairs(Discovery.suites(fs, { LEGACY_ROOT })) do
    modules[#modules + 1] = { module = entry.module, fns = require(entry.module) }
  end
  return modules
end

local _, readyVersions = Capabilities.detect()

return LegacyRomSuite.build({
  modules = legacyModules(),
  readyVersions = readyVersions,
  open = RomFs.open,
})
