-- Project-wide invariants that hold regardless of target map. These are
-- lightweight automated checks for the slice-6 "no target-specific branches"
-- and "no ROM payload checked in" assertions. They read source files through
-- ordinary Lua IO and (for the payload check) ask git what is tracked.

local Assert = require("tests.support.Assert")

local T = {}

-- Modules that must remain target-agnostic: no map symbol, area id, or profile
-- path may appear in their source. Target-specific logic lives in the catalog
-- and the runtime manifests -- never in the renderer or compiler core.
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
      Assert.isTrue(src:find(phrase, 1, true) == nil, path .. " must not contain target-specific phrase: " .. phrase)
    end
  end
end

-- No commercial ROM payload or derived asset may be tracked in git. This is a
-- backstop for the .gitignore rules that already exclude *.nds, .cache/, and
-- data/generated/.
function T.no_rom_payload_tracked()
  local pipe = io.popen("git -C . ls-files 2>/dev/null", "r")
  if not pipe then
    return
  end
  local tracked = pipe:read("*a")
  pipe:close()
  if tracked == "" then
    return
  end -- not a git checkout, skip

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
      Assert.isTrue(line:find(pat) == nil, "tracked file must not be a ROM payload or derived asset: " .. line)
    end
  end
end

-- A bare global `print(` not preceded by `.` or `:` (i.e. not
-- love.graphics.print or a method call) would be terminal output. The
-- preceding-character check excludes identifier characters too, so method
-- names ending in `print` (e.g. `fingerprint(`) are not false positives.
local function hasBarePrint(src)
  return src:match("[^%w_%.%:]print%(") ~= nil or src:match("^print%(") ~= nil
end

-- The interactive game and the reusable runtime libraries must never write to
-- the terminal: recoverable failures surface through state (saveStatus,
-- errorText) or a structured Errors object, and programming failures raise.
-- Deliberate command-line output lives only in the headless romdump CLI and
-- the test runners.
function T.no_terminal_output_from_game_or_runtime_source()
  local pipe = io.popen("git -C . ls-files 2>/dev/null", "r")
  if not pipe then
    return
  end
  local tracked = pipe:read("*a")
  pipe:close()
  if tracked == "" then
    return
  end -- not a git checkout, skip

  for line in tracked:gmatch("[^\r\n]+") do
    if line:match("^game/src/.*%.lua$") or line:match("^libs/[^/]+/src/.*%.lua$") then
      local f = io.open(line, "r")
      if not f then
        -- A tracked file deleted from the working tree (a pending deletion)
        -- has no source content to scan.
        goto continue
      end
      local src = f:read("*a")
      f:close()
      Assert.isTrue(src:find("io.stderr", 1, true) == nil, line .. " must not write to stderr")
      Assert.isTrue(src:find("io.stdout", 1, true) == nil, line .. " must not write to stdout")
      Assert.isTrue(not hasBarePrint(src), line .. " must not call global print")
    end
    ::continue::
  end
end

return T
