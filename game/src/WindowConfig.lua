-- Shared generic window configuration for the game app. love.conf
-- (executed by the LÖVE binary before any game module exists) and the field
-- runtime and field presentation resolve the reference window size from this one module so the
-- two defaults cannot drift apart; the same is true of the background color,
-- which App applies to the LÖVE window and FieldState injects into
-- FieldRenderer so the scene canvas clears to the identical color.

local WindowConfig = {}

-- The reference window resolution: the test window opens at this size and the
-- field viewport falls back to it when no explicit size is configured.
WindowConfig.REFERENCE_WIDTH = 640
WindowConfig.REFERENCE_HEIGHT = 480

-- The game's window/scene background color (RGBA, 0..1). Chosen to sit behind
-- the field's rendered geometry, not a DS-authentic value.
WindowConfig.BACKGROUND_COLOR = { 0.08, 0.09, 0.12, 1 }

-- Parses one environment-provided window dimension (positive integer) or
-- reports a clear rejection. `raw` is the raw env value: nil means the
-- variable is unset and is not an error. The returned message names the
-- variable so the boot failure is diagnosable.

---@param raw string|nil
---@param envName string
---@return integer|nil, string|nil
function WindowConfig.parseEnvDimension(raw, envName)
  if raw == nil then
    return nil, nil
  end
  local n = tonumber(raw)
  if n == nil or n ~= math.floor(n) or n <= 0 then
    return nil, envName .. " must be a positive integer, got " .. raw
  end
  return n --[[@as integer]]
end

return WindowConfig
