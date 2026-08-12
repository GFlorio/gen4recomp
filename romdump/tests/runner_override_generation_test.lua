-- Runner's gen-script-overrides command: the checked-in override files are a
-- published artifact, so a failed run must not leave a partial checked-in
-- rewrite, and the documented first-ready-dump source selection must not
-- silently grow to every ready version. The repo write root is redirected to
-- a temp directory so the tests never touch the real checked-in overrides;
-- the generation, RomFs, readiness, and quit boundaries are stubbed.

local Assert = require("tests.support.Assert")
local RomImporter = require("libs.rom.src.RomImporter")
local RomFs = require("libs.rom.src.RomFs")
local Runner = require("romdump.src.cli.Runner")

local T = {}

local TMP_ROOT = ".agents/tmp/d26-runner-overrides"
local FILES = {
  { id = "0843_001", path = "data/scripts/overrides/0843_001.lua", text = "override one" },
  { id = "0843_002", path = "data/scripts/overrides/0843_002.lua", text = "override two" },
  { id = "0843_003", path = "data/scripts/overrides/0843_003.lua", text = "override three" },
}
local MANIFEST_PATH = "data/scripts/manifests/overrides.lua"

local saved = {}
local generateCalls = {}

local function listFiles(root)
  local files = {}
  local command = "find '" .. root .. "' -type f -print 2>/dev/null"
  local pipe = assert(io.popen(command, "r"), "cannot list " .. root .. ": io.popen unavailable")
  for line in pipe:lines() do
    files[#files + 1] = line
  end
  assert(pipe:close(), "cannot list " .. root)
  return files
end

local module = {
  metadata = {
    layer = "component",
  },
  beforeAll = function()
    saved.isReady = RomImporter.isReady
    saved.romFsOpen = RomFs.open
    saved.getSourceBaseDirectory = love.filesystem.getSourceBaseDirectory
    saved.quit = love.event.quit
    saved.overrideGenerator = package.loaded["romdump.src.digest.script.OverrideGenerator"]
    saved.ioOpen = io.open

    ---@diagnostic disable: duplicate-set-field
    RomImporter.isReady = function()
      return true
    end
    RomFs.open = function(version)
      return { version = version, close = function() end }
    end
    love.filesystem.getSourceBaseDirectory = function()
      return TMP_ROOT
    end
    package.loaded["romdump.src.digest.script.OverrideGenerator"] = {
      generate = function(romFs)
        generateCalls[#generateCalls + 1] = romFs.version
        return FILES
      end,
    }
  end,
  afterAll = function()
    RomImporter.isReady = saved.isReady
    RomFs.open = saved.romFsOpen
    love.filesystem.getSourceBaseDirectory = saved.getSourceBaseDirectory
    love.event.quit = saved.quit
    package.loaded["romdump.src.digest.script.OverrideGenerator"] = saved.overrideGenerator
    io.open = saved.ioOpen
    os.execute("rm -rf '" .. TMP_ROOT .. "'")
  end,
  tests = T,
}

-- A mid-write failure must leave the checked-in override set untouched: the
-- run fails nonzero and no file was rewritten before the failure. The
-- injected failure targets the second override's staged write (any path
-- containing the id; the staged name carries a .new suffix).
function T.override_generation_failure_leaves_no_partial_checked_in_rewrite()
  local realOpen, realQuit = io.open, love.event.quit
  local exitCode
  ---@diagnostic disable: duplicate-set-field
  io.open = function(path, mode)
    if tostring(path):find("0843_002") ~= nil then
      return nil, "injected write failure"
    end
    return realOpen(path, mode)
  end
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner._runGenScriptOverrides()
  end, debug.traceback)
  io.open, love.event.quit = realOpen, realQuit
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 1, "the failed generation must exit nonzero")
  local leftovers = listFiles(TMP_ROOT)
  Assert.equal(#leftovers, 0, "partial override rewrite left behind:\n  " .. table.concat(leftovers, "\n  "))
end

-- The module documents regeneration from the first ready dump; with several
-- ready versions the loop must still generate once and publish every override
-- file and the manifest.
function T.override_generation_uses_only_the_first_ready_dump()
  generateCalls = {}
  local realQuit = love.event.quit
  local exitCode
  love.event.quit = function(code)
    exitCode = code
  end

  local ok, err = xpcall(function()
    Runner._runGenScriptOverrides()
  end, debug.traceback)
  love.event.quit = realQuit
  if not ok then
    error(err, 0)
  end

  Assert.equal(exitCode, 0)
  Assert.deepEqual(generateCalls, { "heartgold" }, "only the first ready dump generates overrides")
  for _, file in ipairs(FILES) do
    local handle = io.open(TMP_ROOT .. "/" .. file.path, "r")
    Assert.notNil(handle, "missing published override " .. file.path)
    if handle then
      Assert.equal(handle:read("*a"), file.text, "published content differs for " .. file.path)
      handle:close()
    end
  end
  Assert.notNil(io.open(TMP_ROOT .. "/" .. MANIFEST_PATH, "r"), "missing published override manifest")
end

return module
