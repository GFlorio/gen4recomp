-- Non-rendering field boot decision. Both the interactive app and acceptance
-- harness use this small policy without coupling version selection to GPU UI.

local FieldBoot = {}

-- One ready version selects it directly; several return the ready array
-- itself so the caller offers a choice over exactly what it found.

---@param versions string[]
---@return string|string[]
function FieldBoot.select(versions)
  assert(type(versions) == "table" and #versions > 0, "at least one ready version required")
  local seen = {}
  for _, versionId in ipairs(versions) do
    assert(type(versionId) == "string" and versionId ~= "", "ready version id required")
    assert(not seen[versionId], "duplicate ready version " .. versionId)
    seen[versionId] = true
  end
  if #versions == 1 then
    return versions[1]
  end
  return versions
end

return FieldBoot
