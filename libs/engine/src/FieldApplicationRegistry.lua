-- Per-runtime application catalogue for the field application host: the
-- Start Menu and its destinations are registered before the registry seals,
-- and dispatch happens only through the sealed registry. Duplicate ids,
-- registration after sealing, unknown application ids, missing factories,
-- and factories returning partial controllers are composition errors; there
-- is no process-global registry. The minimal controller contract is
-- the validation shape: updateFixed(uiInput) mutates pure logical state,
-- status() is presentation data, takeResult() returns at most one
-- { kind = "close"|"launch" } result, and dispose() releases the logical
-- lifetime idempotently. Pure domain module: no love, no I/O.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class FieldApplicationRegistry
---@field sealed boolean true once the registry is closed for registration
---@field _factories table<string, fun(...): table>
---@field _order string[] registration order
local FieldApplicationRegistry = {}
FieldApplicationRegistry.__index = FieldApplicationRegistry

local CONTROLLER_METHODS = { "updateFixed", "status", "takeResult", "dispose" }

local function invalidDescriptor(message, context)
  Errors.raise(FieldErrors.APPLICATION_REGISTRY_INVALID_DESCRIPTOR, message, context)
end

function FieldApplicationRegistry.new()
  return setmetatable({
    sealed = false,
    _factories = {},
    _order = {},
  }, FieldApplicationRegistry)
end

-- Registers one application factory. The factory must return a fully usable
-- controller or raise; a partial result is a composition error caught at
-- dispatch (create), not silently accepted.
---@param descriptor { id: string, factory: fun(...): table }
function FieldApplicationRegistry:register(descriptor)
  if self.sealed then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_ALREADY_SEALED, "cannot register an application after seal", {})
  end
  if type(descriptor) ~= "table" or type(descriptor.id) ~= "string" or descriptor.id == "" then
    invalidDescriptor("application descriptors need a non-empty id", { id = descriptor and descriptor.id })
  end
  if type(descriptor.factory) ~= "function" then
    invalidDescriptor("application " .. descriptor.id .. " needs a factory", { id = descriptor.id })
  end
  if self._factories[descriptor.id] ~= nil then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_DUPLICATE_ID, "duplicate application id", { id = descriptor.id })
  end
  self._factories[descriptor.id] = descriptor.factory
  self._order[#self._order + 1] = descriptor.id
end

function FieldApplicationRegistry:seal()
  if self.sealed then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_ALREADY_SEALED, "the application registry is already sealed", {})
  end
  self.sealed = true
end

local function requireSealed(self)
  if not self.sealed then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_NOT_SEALED, "the application registry is not sealed", {})
  end
end

-- Whether a destination application is registered and dispatchable.
---@param id string
---@return boolean
function FieldApplicationRegistry:has(id)
  requireSealed(self)
  return self._factories[id] ~= nil
end

-- The sealed application-id set, used by the Start Menu policy adapter as
-- the application-capability set. Fresh table per call.
---@return string[]
function FieldApplicationRegistry:ids()
  requireSealed(self)
  local ids = {}
  for index, id in ipairs(self._order) do
    ids[index] = id
  end
  return ids
end

-- Dispatches one application construction through the registered factory.
-- Extra arguments are forwarded to the factory (the application host passes
-- the remembered Start Menu selection when composing the menu itself).
---@param id string
---@return table controller
function FieldApplicationRegistry:create(id, ...)
  requireSealed(self)
  if self._factories[id] == nil then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_UNKNOWN_ID, "unknown application id", { id = id })
  end
  local factory = assert(self._factories[id])
  local controller = factory(...)
  if type(controller) ~= "table" then
    Errors.raise(
      FieldErrors.APPLICATION_REGISTRY_INVALID_CONTROLLER,
      "application " .. id .. " factory must return a controller",
      { id = id }
    )
  end
  for _, method in ipairs(CONTROLLER_METHODS) do
    if type(controller[method]) ~= "function" then
      Errors.raise(
        FieldErrors.APPLICATION_REGISTRY_INVALID_CONTROLLER,
        "application " .. id .. " returned a partial controller",
        { id = id, missing = method }
      )
    end
  end
  return controller
end

return FieldApplicationRegistry
