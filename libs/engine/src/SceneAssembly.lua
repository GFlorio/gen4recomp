-- One submission-order owner for the flattened scene. Draw producers -- scene
-- geometry, the neighbour ring, actor draws -- carry no submission numbers;
-- the final scene assembly concatenates them in desired source order (map,
-- buildings, neighbours, actors), so the flat list position IS the
-- deterministic submission order and cross-group tie ordering is decided here
-- and nowhere else. `flatten(parts)` returns the original item tables: it
-- never copies per-frame data or stamps fields back onto the producers'
-- persistent draw records (the renderer resolves each billboard's per-frame
-- `transform` from its pristine `billboardBase` before any read, and the
-- queue's sort decorations are local to the draw pass). Pure domain module:
-- no love dependency, arithmetic only.

local SceneAssembly = {}

-- parts: an ordered array of draw lists; each element is an array of draw
-- items. Returns the flattened list, concatenated in part/source order: the
-- item's position in the returned list is its submission order.
---@param parts table[]
---@return table[]
function SceneAssembly.flatten(parts)
  assert(type(parts) == "table", "scene assembly needs an ordered array of draw lists")
  local out = {}
  for _, draws in ipairs(parts) do
    assert(type(draws) == "table", "a scene assembly part must be a table of draw items")
    for _, item in ipairs(draws) do
      assert(type(item) == "table", "a scene assembly draw item must be a table")
      out[#out + 1] = item
    end
  end
  return out
end

return SceneAssembly
