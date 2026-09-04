-- Per-runtime application catalogue for the field application host: the
-- catalogue is immutable after construction -- descriptors are validated at
-- new() and dispatch happens through has/create. Duplicate ids, malformed
-- descriptors, unknown application ids, missing factories, and factories
-- returning partial controllers are composition errors; there is no
-- process-global registry. The minimal controller contract is the
-- validation shape: updateFixed(uiInput) mutates pure logical state,
-- status() is presentation data, takeResult() returns at most one
-- { kind = "close"|"launch" } result, and dispose() releases the logical
-- lifetime idempotently. Pure domain module: no love, no I/O.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldApplicationRegistry
---@field _factories table<string, fun(...): table<string, unknown>>
local FieldApplicationRegistry = {}
FieldApplicationRegistry.__index = FieldApplicationRegistry

local CONTROLLER_METHODS = { "updateFixed", "status", "takeResult", "dispose" }

local function invalidDescriptor(message, context)
  Errors.raise(FieldErrors.APPLICATION_REGISTRY_INVALID_DESCRIPTOR, message, context)
end

-- The immutable construction boundary: every descriptor is validated once
-- here (table, non-empty id, factory function, no duplicate ids) and stored
-- in a factory map the runtime never mutates.
---@param descriptors { id: string, factory: fun(...): table<string, unknown> }[]
---@return FieldApplicationRegistry
function FieldApplicationRegistry.new(descriptors)
  assert(type(descriptors) == "table", "the application registry requires a descriptor list")
  local factories = {}
  for _, descriptor in ipairs(descriptors) do
    if type(descriptor) ~= "table" or type(descriptor.id) ~= "string" or descriptor.id == "" then
      invalidDescriptor("application descriptors need a non-empty id", { id = descriptor and descriptor.id })
    end
    if type(descriptor.factory) ~= "function" then
      invalidDescriptor("application " .. descriptor.id .. " needs a factory", { id = descriptor.id })
    end
    if factories[descriptor.id] ~= nil then
      Errors.raise(FieldErrors.APPLICATION_REGISTRY_DUPLICATE_ID, "duplicate application id", { id = descriptor.id })
    end
    factories[descriptor.id] = descriptor.factory
  end
  return setmetatable({ _factories = factories }, FieldApplicationRegistry)
end

-- Whether a destination application is registered and dispatchable.
---@param id string
---@return boolean
function FieldApplicationRegistry:has(id)
  return self._factories[id] ~= nil
end

-- Dispatches one application construction through the registered factory.
-- The registry holds child destinations only; the Start Menu is composed by
-- the application host's own menu factory, so no arguments are forwarded.
---@param id string
---@return table<string, unknown> controller
function FieldApplicationRegistry:create(id)
  if self._factories[id] == nil then
    Errors.raise(FieldErrors.APPLICATION_REGISTRY_UNKNOWN_ID, "unknown application id", { id = id })
  end
  local factory = assert(self._factories[id])
  local controller = factory()
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
