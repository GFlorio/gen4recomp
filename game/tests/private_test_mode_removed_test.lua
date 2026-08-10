-- The private test mode is retired. `scripts/test.sh` is the single test
-- entrypoint, so the second plumbing -- the ROM-conformance flag parsed by the app
-- entry point and its LÖVE configuration, and the shell wrapper that passed it
-- -- must be gone rather than kept as a compatibility alias.
--
-- The app entry point is checked by reading its source because `game/main.lua`
-- installs LÖVE callbacks and cannot be required from a test. The repo-wide
-- scan is the backstop, and covers docs as well as code. Needles are assembled at runtime so this module does
-- not match itself.

local Assert = require("tests.support.Assert")

local T = {}

local FLAG = "--test" .. "-private"
local SCRIPT = "test-" .. "private.sh"
local FIELD = "test" .. "Private"

local SCANNED_EXTENSIONS = {
  lua = true,
  sh = true,
  md = true,
  yml = true,
  yaml = true,
  json = true,
  txt = true,
  glsl = true,
}

local function readFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local contents = handle:read("*a")
  handle:close()
  return contents
end

-- Tracked text files, or nil outside a git checkout.
---@return string[]|nil
local function trackedTextFiles()
  local pipe = io.popen("git -C . ls-files 2>/dev/null", "r")
  if pipe == nil then
    return nil
  end
  local listing = pipe:read("*a")
  pipe:close()
  if listing == nil or listing == "" then
    return nil
  end
  local paths = {}
  for path in listing:gmatch("[^\n]+") do
    local extension = path:match("%.([%w]+)$")
    if extension ~= nil and SCANNED_EXTENSIONS[extension:lower()] then
      paths[#paths + 1] = path
    end
  end
  return paths
end

-- The app entry point and its LÖVE configuration no longer know about a
-- private test mode, and the wrapper script is gone.
function T.the_app_no_longer_has_a_private_test_mode()
  for _, path in ipairs({ "game/main.lua", "game/conf.lua" }) do
    local source = assert(readFile(path), "can read " .. path)
    Assert.isTrue(source:find(FLAG, 1, true) == nil, path .. " must not parse or document " .. FLAG)
    Assert.isTrue(source:find(FIELD, 1, true) == nil, path .. " must not carry a " .. FIELD .. " option")
  end
  Assert.isNil(readFile("scripts/" .. SCRIPT), "scripts/" .. SCRIPT .. " must be deleted, not kept as an alias")
end

-- No tracked file anywhere still references the retired command
-- surface -- code, scripts, and docs alike.
function T.no_tracked_file_references_the_retired_command(context)
  local paths = trackedTextFiles()
  if paths == nil then
    context:skip("not a git checkout, so the tracked-file scan cannot run")
    return
  end

  local offenders = {}
  for _, path in ipairs(paths) do
    local source = readFile(path)
    if source ~= nil then
      for _, needle in ipairs({ FLAG, SCRIPT, FIELD }) do
        if source:find(needle, 1, true) ~= nil then
          offenders[#offenders + 1] = path .. " -> " .. needle
        end
      end
    end
  end

  Assert.isTrue(#offenders == 0, "retired private-test references remain: " .. table.concat(offenders, ", "))
end

return T
