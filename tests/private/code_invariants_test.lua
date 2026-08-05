-- Project-wide invariants that hold regardless of target map. These are
-- lightweight automated checks for the slice-6 "no target-specific branches"
-- and "no ROM payload checked in" assertions. They read source files through
-- ordinary Lua IO and (for the payload check) ask git what is tracked.

local Assert = require("tests.support.Assert")

local T = {}

-- Modules that must remain target-agnostic: no map symbol, area id, or profile
-- path may appear in their source. Target-specific logic lives in the catalog,
-- anchors, and diagnostic state -- never in the renderer or compiler core.
function T.no_target_specific_branches_in_core()
  local modules = {
    "romdump/src/digest/nitro/Nsbmd.lua",
    "romdump/src/digest/MaterialCompiler.lua",
    "romdump/src/digest/MeshCompiler.lua",
    "libs/engine/src/MapRenderer.lua",
    "libs/engine/src/shaders/map.glsl",
  }
  local forbidden = {
    "MAP_NEW_BARK",
    "ELMS_LAB",
    "area00light",
    "area01light",
    "lightTypeRaw ==",
  }
  for _, path in ipairs(modules) do
    local f = assert(io.open(path, "r"), "can read " .. path)
    local src = f:read("*a")
    f:close()
    for _, phrase in ipairs(forbidden) do
      Assert.isTrue(src:find(phrase, 1, true) == nil,
        path .. " must not contain target-specific phrase: " .. phrase)
    end
  end
end

-- No commercial ROM payload or derived asset may be tracked in git. This is a
-- backstop for the .gitignore rules that already exclude *.nds, .cache/, and
-- data/generated/.
function T.no_rom_payload_tracked()
  local pipe = io.popen("git -C . ls-files 2>/dev/null", "r")
  if not pipe then return end
  local tracked = pipe:read("*a")
  pipe:close()
  if tracked == "" then return end -- not a git checkout, skip

  local disallowedPatterns = {
    "%.nds$",
    "%.sav$",
    "^%.cache/",
    "^data/generated/",
    "^assets/generated/",
    "^romfs/",
    "^import%-output/",
  }
  for line in tracked:gmatch("[^\r\n]+") do
    for _, pat in ipairs(disallowedPatterns) do
      Assert.isTrue(line:find(pat) == nil,
        "tracked file must not be a ROM payload or derived asset: " .. line)
    end
  end
end

return T
