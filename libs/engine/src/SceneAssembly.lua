-- One submission-order owner for the flattened scene. Draw producers -- scene
-- geometry, the neighbour ring, actor draws -- carry no submission numbers;
-- the final scene assembly assigns monotonically increasing submission
-- indices in desired source order (map, buildings, neighbours, actors), so
-- cross-group tie ordering is decided here and nowhere else. `flatten(parts)`
-- numbers every draw of the first part, then the second, and so on, and
-- returns stamped copies: repeated per-frame assembly never mutates the
-- producers' persistent draw records, and any submission number a producer
-- still carries is replaced by the assembly's own. Pure domain module: no
-- love dependency, arithmetic only.

local SceneAssembly = {}

-- parts: an ordered array of draw lists; each element is an array of draw
-- items. Returns the flattened list: one shallow copy per item, numbered
-- 1..N in part/source order.
---@param parts table[]
---@return table[]
function SceneAssembly.flatten(parts)
  assert(type(parts) == "table", "scene assembly needs an ordered array of draw lists")
  local out = {}
  local submission = 0
  for _, draws in ipairs(parts) do
    assert(type(draws) == "table", "a scene assembly part must be a table of draw items")
    for _, item in ipairs(draws) do
      assert(type(item) == "table", "a scene assembly draw item must be a table")
      submission = submission + 1
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      copy.submissionIndex = submission
      out[#out + 1] = copy
    end
  end
  return out
end

return SceneAssembly
