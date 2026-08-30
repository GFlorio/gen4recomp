-- Classifies normalized collision behavior into the semantic choices available
-- to player-input movement. It has no terrain, actor, progression, or host
-- dependencies; FieldPlayer owns all stateful validation and motion timing.

local MetatileBehavior = require("libs.hgss.src.field.MetatileBehavior")

local FieldTraversal = {}

---@param destination table
---@param direction FieldDirection
---@return table
function FieldTraversal.classify(destination, direction)
  assert(type(destination) == "table", "destination permission record required")
  assert(type(direction) == "string", "traversal direction required")

  local action = MetatileBehavior.fieldAction(destination.behavior)
  if action then
    return { kind = "field_action", action = action }
  end

  local ledgeDirection = MetatileBehavior.ledgeDirection(destination.behavior)
  if ledgeDirection then
    if ledgeDirection ~= direction then
      return { kind = "blocked" }
    end
    return { kind = "ledge_jump" }
  end

  if destination.blocked then
    return { kind = "blocked" }
  end
  return { kind = "step" }
end

return FieldTraversal
