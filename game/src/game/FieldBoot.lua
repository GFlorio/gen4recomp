-- Non-rendering field boot decision. Both the interactive app and acceptance
-- harness use this small policy without coupling version selection to GPU UI.

local FieldBoot = {}

local Selection = {}
Selection.__index = Selection

function Selection:versions()
  local versions = {}
  for index, versionId in ipairs(self._versions) do
    versions[index] = versionId
  end
  return versions
end

function Selection:choose(versionId)
  assert(self._available[versionId], "unknown ready version " .. tostring(versionId))
  return versionId
end

---@param versions string[]
---@return string|table
function FieldBoot.select(versions)
  assert(type(versions) == "table" and #versions > 0, "at least one ready version required")
  local available = {}
  local copied = {}
  for index, versionId in ipairs(versions) do
    assert(type(versionId) == "string" and versionId ~= "", "ready version id required")
    assert(not available[versionId], "duplicate ready version " .. versionId)
    available[versionId] = true
    copied[index] = versionId
  end
  if #versions == 1 then
    return copied[1]
  end
  return setmetatable({ _versions = copied, _available = available }, Selection)
end

return FieldBoot
