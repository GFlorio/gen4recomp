-- Paths of the mod-facing script-override assets: the checked-in override
-- files (data/scripts/overrides/<script-id>.lua) and the manifest that lists
-- them (data/scripts/manifests/overrides.lua). The digest CLI
-- (romdump) regenerates these assets and the runtime loads them, so the
-- paths live here as the single owner; ScriptLoader and the override
-- generator reference them. Paths are repo-relative. Pure data module.

local ScriptOverrides = {}

ScriptOverrides.DIR = "data/scripts/overrides"
ScriptOverrides.MANIFEST = "data/scripts/manifests/overrides.lua"

return ScriptOverrides
