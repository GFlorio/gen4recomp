-- Temporary bridge from the legacy private modules to the single runner. Those
-- modules are `name -> function(romFs, versionId)` tables that used to be driven
-- by their own runner; here they become one ROM-layer suite whose setup owns a
-- RomFs per ready version and whose cleanup releases each exactly once.
--
-- This file goes away with `tests/rom/legacy_private_suite_test.lua` once the
-- modules are migrated to `tests/rom/` proper.

local LegacyRomSuite = {}

local function closeAll(handles)
  for _, handle in ipairs(handles) do
    handle.romFs:close()
  end
end

-- Builds the suite table the runner normalizes.
---@param options { modules: { module: string, fns: table<string, fun(romFs: table, versionId: string)> }[], readyVersions: string[], open: fun(versionId: string): table|nil, string|nil }
---@return table suite
function LegacyRomSuite.build(options)
  local modules = assert(options.modules, "LegacyRomSuite needs modules")
  local readyVersions = assert(options.readyVersions, "LegacyRomSuite needs the ready versions")
  local open = assert(options.open, "LegacyRomSuite needs a RomFs opener")

  -- Owned by the suite between beforeAll and afterAll; nil means nothing is held.
  local handles = nil

  local suite = {
    metadata = { layer = "rom", capabilities = { "rom_dump" } },
    tests = {},
  }

  function suite.beforeAll()
    local opened = {}
    handles = opened
    for _, versionId in ipairs(readyVersions) do
      local romFs, err = open(versionId)
      if romFs == nil then
        handles = nil
        closeAll(opened)
        error("cannot open the dump of " .. versionId .. ": " .. tostring(err), 0)
      end
      opened[#opened + 1] = { versionId = versionId, romFs = romFs }
    end
  end

  function suite.afterAll()
    local opened = handles
    handles = nil
    if opened ~= nil then
      closeAll(opened)
    end
  end

  for _, entry in ipairs(modules) do
    local shortName = entry.module:match("([^%.]+)$") or entry.module
    for name, fn in pairs(entry.fns) do
      suite.tests[shortName .. "." .. name] = function()
        for _, handle in ipairs(assert(handles, "the legacy ROM suite has no open dump")) do
          local ok, err = pcall(fn, handle.romFs, handle.versionId)
          if not ok then
            error(handle.versionId .. ": " .. tostring(err), 0)
          end
        end
      end
    end
  end

  return suite
end

return LegacyRomSuite
