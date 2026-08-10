-- ROM/cache pipeline orchestration. It selects ready supported dumps and joins
-- preparation, audit, source import, and non-rendering runtime boot without
-- making the CLI or its host event loop part of those operations.

---@class CachePipeline
---@field versionOrder string[]
---@field isReady fun(versionId: string): boolean
---@field prepareVersion fun(versionId: string): table|nil, unknown?
---@field auditVersion fun(versionId: string): table
---@field bootRuntime fun(versionId: string): table
---@field importSource fun(source: string, root: string): table|nil, unknown?
---@field createIsolatedRoot fun(): string
---@field removeIsolatedRoot fun(root: string): boolean, string|nil
local CachePipeline = {}
CachePipeline.__index = CachePipeline

---@param options table<string, unknown>
---@param name string
---@return function
local function requireFunction(options, name)
  assert(type(options[name]) == "function", "CachePipeline requires " .. name)
  return options[name]
end

---@class CachePipelineOptions
---@field versionOrder string[]
---@field isReady fun(versionId: string): boolean
---@field prepareVersion fun(versionId: string): table|nil, unknown?
---@field auditVersion fun(versionId: string): table
---@field bootRuntime fun(versionId: string): table
---@field importSource fun(source: string, root: string): table|nil, unknown?
---@field createIsolatedRoot fun(): string
---@field removeIsolatedRoot fun(root: string): boolean, string|nil

---@class CachePipelineProductionOptions
---@field versionOrder? string[]
---@field isReady? fun(versionId: string): boolean
---@field prepareVersion? fun(versionId: string): table|nil, unknown?
---@field auditVersion? fun(versionId: string): table
---@field bootRuntime? fun(versionId: string): table
---@field importSource? fun(source: string, root: string): table|nil, unknown?
---@field createIsolatedRoot? fun(): string
---@field removeIsolatedRoot? fun(root: string): boolean, string|nil

---@param options CachePipelineOptions
---@return CachePipeline
function CachePipeline.new(options)
  assert(type(options) == "table", "CachePipeline options required")
  assert(type(options.versionOrder) == "table", "CachePipeline requires versionOrder")
  return setmetatable({
    versionOrder = options.versionOrder,
    isReady = requireFunction(options, "isReady"),
    prepareVersion = requireFunction(options, "prepareVersion"),
    auditVersion = requireFunction(options, "auditVersion"),
    bootRuntime = requireFunction(options, "bootRuntime"),
    importSource = requireFunction(options, "importSource"),
    createIsolatedRoot = requireFunction(options, "createIsolatedRoot"),
    removeIsolatedRoot = requireFunction(options, "removeIsolatedRoot"),
  }, CachePipeline)
end

-- Production defaults keep the orchestration independent from the CLI event
-- loop. Building and importing remain explicit host operations because the
-- former reports compile exclusions and the latter is coroutine-driven.
---@param options CachePipelineProductionOptions?
---@return CachePipeline
function CachePipeline.production(options)
  options = options or {}
  local GameVersion = require("libs.rom.src.GameVersion")
  local RomImporter = require("libs.rom.src.RomImporter")
  local DumpAudit = require("libs.rom.src.DumpAudit")
  return CachePipeline.new({
    versionOrder = options.versionOrder or GameVersion.ORDER,
    isReady = options.isReady or RomImporter.isReady,
    prepareVersion = options.prepareVersion or function()
      error("CachePipeline production prepareVersion adapter required", 2)
    end,
    auditVersion = options.auditVersion or DumpAudit.run,
    bootRuntime = options.bootRuntime or function(versionId)
      return require("game.src.game.FieldRuntime").new(versionId)
    end,
    importSource = options.importSource or function()
      error("CachePipeline production importSource adapter required", 2)
    end,
    createIsolatedRoot = options.createIsolatedRoot or function()
      error("CachePipeline production createIsolatedRoot adapter required", 2)
    end,
    removeIsolatedRoot = options.removeIsolatedRoot or function()
      error("CachePipeline production removeIsolatedRoot adapter required", 2)
    end,
  })
end

---@return string[]
function CachePipeline:readyVersions()
  local versions = {}
  for _, versionId in ipairs(self.versionOrder) do
    if self.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

---@return table<string, table>
function CachePipeline:prepareReady()
  local reports = {}
  for _, versionId in ipairs(self:readyVersions()) do
    local report, err = self.prepareVersion(versionId)
    assert(report, err)
    assert(report.current == true, "prepared cache must report current for " .. versionId)
    reports[versionId] = report
  end
  return reports
end

---@return table<string, table>
function CachePipeline:auditReady()
  local reports = {}
  for _, versionId in ipairs(self:readyVersions()) do
    reports[versionId] = self.auditVersion(versionId)
  end
  return reports
end

---@param versionId string
---@return table
function CachePipeline:bootPrepared(versionId)
  assert(self.isReady(versionId), "no ready dump for " .. tostring(versionId))
  local runtime = self.bootRuntime(versionId)
  assert(runtime, "prepared runtime did not boot for " .. versionId)
  return runtime
end

---@param source string
---@return table
function CachePipeline:runSource(source)
  local root = self.createIsolatedRoot()
  assert(type(root) == "string" and root ~= "", "isolated root required")
  local ok, report = xpcall(function()
    local imported, importErr = self.importSource(source, root)
    assert(imported, importErr)
    local versionId = imported.versionId
    assert(type(versionId) == "string", "import must report versionId")
    local audit = self.auditVersion(versionId)
    local prepared, prepareErr = self.prepareVersion(versionId)
    assert(prepared, prepareErr)
    assert(prepared.current == true, "prepared cache must report current for " .. versionId)
    local runtime = self:bootPrepared(versionId)
    assert(type(runtime.dispose) == "function", "prepared runtime must be disposable")
    runtime:dispose()
    return { versionId = versionId, audit = audit, prepared = prepared }
  end, debug.traceback)
  local removed, removeResult, removeErr = pcall(self.removeIsolatedRoot, root)
  if not ok then
    error(report, 0)
  end
  assert(removed, removeResult)
  assert(removeResult, removeErr or "failed to remove isolated root")
  return report
end

return CachePipeline
