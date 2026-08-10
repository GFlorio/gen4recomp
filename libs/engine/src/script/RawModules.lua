-- Ownership-aware raw module registry : raw-Lua
-- handler modules register here at mod-load time with their owning mod id,
-- and the runtime resolves them by module name. Modules load from their
-- owning content root through the game's mod loader; this registry only maps
-- names to module tables and owners, and rejects unknown modules with
-- attributed errors. Engine-internal module imports are rejected by the mod
-- loader's restricted environment. Pure domain module:
-- no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

---@class RawModules
---@field private _modules table<string, table>
---@field private _owners table<string, table>
local RawModules = {}
RawModules.__index = RawModules

---@return RawModules
function RawModules.new()
  return setmetatable({ _modules = {}, _owners = {} }, RawModules)
end

-- Register a handler module under its module name. The owner names the mod
-- that contributed it, matching the registry owner shapes `{modId, api}` or
-- `{kind, id, api}`; a duplicate registration is a hard load error.
---@param moduleName string
---@param module table
---@param owner table
function RawModules:register(moduleName, module, owner)
  assert(type(moduleName) == "string" and moduleName ~= "", "module name required")
  assert(type(module) == "table", "raw module must be a table")
  if
    type(owner) ~= "table"
    or (owner.modId == nil and (type(owner.kind) ~= "string" or type(owner.id) ~= "string" or owner.id == ""))
  then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "raw module owner must be {modId, api} or {kind, id, api}",
      { module = moduleName, owner = owner }
    )
  end
  if self._modules[moduleName] ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_MODULE_DUPLICATE,
      "raw module is registered twice: " .. moduleName,
      { module = moduleName, owner = owner, existingOwner = self._owners[moduleName] }
    )
  end
  self._modules[moduleName] = module
  self._owners[moduleName] = owner
end

-- Resolve a handler module; missing modules are attributed raw errors.
---@param moduleName string
---@return table module, table|nil owner
function RawModules:resolve(moduleName)
  local module = self._modules[moduleName]
  if module == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_RAW_MODULE_NOT_FOUND,
      "no registered raw module " .. moduleName,
      { module = moduleName }
    )
  end
  module = module --[[@as table]]
  return module, self._owners[moduleName]
end

-- The registered module names, sorted (diagnostics and hot-reload checks).
---@return string[]
function RawModules:moduleNames()
  local out = {}
  for name in pairs(self._modules) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

return RawModules
