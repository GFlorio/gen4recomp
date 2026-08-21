-- Paths of explicit script-override assets: override files under
-- data/scripts/overrides and the manifest that lists them. The runtime loads
-- these paths through one owner; paths are repo-relative. Pure data module.

local ScriptOverrides = {}

ScriptOverrides.DIR = "data/scripts/overrides"
ScriptOverrides.MANIFEST = "data/scripts/manifests/overrides.lua"

return ScriptOverrides
