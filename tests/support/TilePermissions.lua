-- Permissions stub over a tiles table mapping "fieldX:fieldZ" to
-- { behavior = byte, blocked = boolean }, for unit tests exercising warp
-- trigger and field-walk semantics without a ROM. Shared by the
-- TransitionTrigger and FieldSession suites; unknown tiles default to
-- behavior 0 (plain floor) and walkable.

local TilePermissions = {}

---@param tiles table<string, {behavior: integer?, blocked: boolean?}>?
---@return table
function TilePermissions.new(tiles)
  tiles = tiles or {}
  return {
    containsLocal = function(_, x, z)
      return x >= 0 and x < 32 and z >= 0 and z < 32
    end,
    getLocal = function(_, x, z)
      local record = tiles[x .. ":" .. z]
      return { behavior = record and record.behavior or 0, hardBlocked = record and record.blocked or false }
    end,
    isBlockedLocal = function(_, x, z)
      local record = tiles[x .. ":" .. z]
      return record ~= nil and record.blocked
    end,
  }
end

return TilePermissions
