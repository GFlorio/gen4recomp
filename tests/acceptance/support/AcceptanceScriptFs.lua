-- Test-only read overlay for acceptance script resources. It extends the
-- checked-in manifest in memory so injected scripts use the normal override
-- loader and validator without becoming production registry content.

local ScriptOverrides = require("libs.assets.src.ScriptOverrides")

local AcceptanceScriptFs = {}
AcceptanceScriptFs.__index = AcceptanceScriptFs

---@param base table read-shaped repository filesystem
---@param scripts table<string, string> script id to Lua resource source
---@return table
function AcceptanceScriptFs.new(base, scripts)
  assert(base and type(base.read) == "function", "acceptance script base filesystem required")
  assert(type(scripts) == "table", "acceptance scripts required")
  local ids = {}
  for id, source in pairs(scripts) do
    assert(type(id) == "string" and id ~= "", "acceptance script id required")
    assert(type(source) == "string", "acceptance script source required")
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return setmetatable({ base = base, scripts = scripts, ids = ids }, AcceptanceScriptFs)
end

function AcceptanceScriptFs:read(path)
  if path == ScriptOverrides.MANIFEST then
    local manifest = assert(self.base:read(path), "production override manifest missing")
    local additions = {}
    for _, id in ipairs(self.ids) do
      additions[#additions + 1] = "  " .. string.format("%q", id) .. ",\n"
    end
    local updated, count = manifest:gsub("}\n$", table.concat(additions) .. "}\n")
    assert(count == 1, "production override manifest must end with a table")
    return updated
  end
  local prefix = ScriptOverrides.DIR .. "/"
  if path:sub(1, #prefix) == prefix and path:sub(-4) == ".lua" then
    local id = path:sub(#prefix + 1, -5)
    if self.scripts[id] ~= nil then
      return self.scripts[id]
    end
  end
  return self.base:read(path)
end

return AcceptanceScriptFs
