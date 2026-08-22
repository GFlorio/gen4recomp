-- Evaluates generated field-map initialization rules at the pre-input
-- boundary. The scheduler remains the sole owner of script execution.

---@class MapInitScriptController
---@field rules table
---@field world table
---@field scriptClient table
---@field mapId integer|nil
local MapInitScriptController = {}
MapInitScriptController.__index = MapInitScriptController

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

local function validateRules(rules, mapId)
  for _, group in ipairs(rules) do
    if group.type ~= "on_frame_eq" then
      Errors.raise(FieldErrors.MAP_INIT_UNSUPPORTED_LIFECYCLE, "map init lifecycle is not executable", {
        type = group.type,
        scriptId = group.scriptId,
        mapId = mapId,
      })
    end
  end
end

---@param opts table { rules: table, world: table, scriptClient: table }
---@return MapInitScriptController
function MapInitScriptController.new(opts)
  assert(opts and type(opts.rules) == "table", "map init rules required")
  assert(opts.world and opts.world.getVar, "map init world required")
  assert(opts.scriptClient and opts.scriptClient.startInitScript, "map init client required")
  validateRules(opts.rules, opts.mapId)
  return setmetatable(
    { rules = opts.rules, world = opts.world, scriptClient = opts.scriptClient, mapId = opts.mapId },
    MapInitScriptController
  )
end

function MapInitScriptController:setRules(rules, mapId)
  assert(type(rules) == "table", "map init rules required")
  validateRules(rules, mapId == nil and self.mapId or mapId)
  self.mapId = mapId == nil and self.mapId or mapId
  self.rules = rules
end

---@param tick integer
---@return boolean claimed
function MapInitScriptController:evaluate(tick)
  for _, group in ipairs(self.rules) do
    for _, rule in ipairs(group.rules) do
      if self.world:getVar(rule.variableId) == rule.equals then
        return self.scriptClient:startInitScript(rule.scriptId, tick) == true
      end
    end
  end
  return false
end

return MapInitScriptController
