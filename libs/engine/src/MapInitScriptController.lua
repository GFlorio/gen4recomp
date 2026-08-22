-- Evaluates generated field-map initialization rules at the pre-input
-- boundary. The scheduler remains the sole owner of script execution.

---@class MapInitScriptController
---@field rules table
---@field world table
---@field scriptClient table
local MapInitScriptController = {}
MapInitScriptController.__index = MapInitScriptController

---@param opts table { rules: table, world: table, scriptClient: table }
---@return MapInitScriptController
function MapInitScriptController.new(opts)
  assert(opts and type(opts.rules) == "table", "map init rules required")
  assert(opts.world and opts.world.getVar, "map init world required")
  assert(opts.scriptClient and opts.scriptClient.startInitScript, "map init client required")
  return setmetatable(
    { rules = opts.rules, world = opts.world, scriptClient = opts.scriptClient },
    MapInitScriptController
  )
end

function MapInitScriptController:setRules(rules)
  assert(type(rules) == "table", "map init rules required")
  self.rules = rules
end

---@param tick integer
---@return boolean claimed
function MapInitScriptController:evaluate(tick)
  for _, group in ipairs(self.rules) do
    assert(group.type == "on_frame_eq", "unsupported map init rule type " .. tostring(group.type))
    for _, rule in ipairs(group.rules) do
      if self.world:getVar(rule.variableId) == rule.equals then
        local target = rule.scriptId or rule.scriptIndex
        assert(target ~= nil, "map init rule target is missing")
        return self.scriptClient:startInitScript(target, tick) == true
      end
    end
  end
  return false
end

return MapInitScriptController
