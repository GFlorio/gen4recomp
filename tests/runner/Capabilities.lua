-- Detects the capabilities a test run has available. Two are owned here:
--
--   rom_dump      at least one GameVersion is ready through RomImporter.isReady
--   derived_cache the incremental cache builder ran successfully for that dump
--
-- Readiness of the derived cache is not re-derived from markers: preparation is
-- the shell entrypoint's step (`scripts/test.sh` runs `love romdump/
-- --build-cache` before the ROM-gated layers) and it reports the outcome through
-- G4RECOMP_DERIVED_CACHE_READY. A ready raw dump alone therefore never claims a
-- current derived cache.

local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")

local Capabilities = {}

Capabilities.DERIVED_CACHE_ENV = "G4RECOMP_DERIVED_CACHE_READY"

---@class CapabilityOptions
---@field env table<string, string>|nil
---@field isReady (fun(versionId: string): boolean)|nil
---@field versions string[]|nil

-- `options.env` is supplied by the caller (see `tests/run.lua`) so detection
-- never depends on the ambient environment; `isReady`/`versions` are injected by
-- this module's own tests.
---@param options CapabilityOptions|nil
---@return table<string, boolean> capabilities, string[] readyVersions
function Capabilities.detect(options)
  options = options or {}
  local env = options.env or {}
  local isReady = options.isReady or RomImporter.isReady
  local versions = options.versions or GameVersion.ORDER

  local ready = {}
  for _, versionId in ipairs(versions) do
    if isReady(versionId) then
      ready[#ready + 1] = versionId
    end
  end

  local capabilities = {}
  if #ready > 0 then
    capabilities.rom_dump = true
    if env[Capabilities.DERIVED_CACHE_ENV] == "1" then
      capabilities.derived_cache = true
    end
  end
  return capabilities, ready
end

return Capabilities
