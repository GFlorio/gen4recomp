-- Frozen id -> name view of the project-owned script-symbol contract, in the
-- direction the script decoder needs for naming operands. The name -> id
-- surface (the mod-facing direction) lives in libs/assets
-- FieldScriptSymbols; this module derives from it so the two can never drift.

local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local byId = {}
for name, id in pairs(FieldScriptSymbols.flagsByName) do
  byId[id] = name
end

return { byId = byId }
