-- Pure Lua reference for the DS GPU3D edge-marking predicate: whether a pixel
-- is an edge center, and which of the eight edge-color table entries applies.
-- No love dependency, arithmetic only.
--
-- Authoritative source: GBATEK "4000330h..33Fh - EDGE_COLOR". A pixel is
-- marked when at least one of its four orthogonal neighbors (up, down, left,
-- right -- never diagonals) carries a different polygon ID *and* the center
-- pixel is strictly in front of that neighbor (DsDepth.isInFront). Depth
-- equality between differently-ID'd pixels is a coplanar boundary (adjacent
-- ground batches, flat decals) and must not be marked; DsDepth.isInFront is
-- already strict for that reason. Off-screen/missing neighbors contribute no
-- edge. The marked pixel's own edge color is selected from an eight-entry
-- table indexed by its polygon ID shifted right by 3 (centerPolygonId >> 3),
-- i.e. eight buckets of eight consecutive polygon IDs each.

local DsDepth = require("libs.engine.src.DsDepth")

local DsEdgeMarking = {}

-- Edge-color table index for a polygon ID (0..63): centerPolygonId >> 3.
function DsEdgeMarking.edgeTableIndex(polygonId)
  return math.floor(polygonId / 8)
end

local function qualifies(center, neighbor)
  if neighbor == nil then
    return false
  end
  return neighbor.polygonId ~= center.polygonId and DsDepth.isInFront(center.depth, neighbor.depth)
end

-- True when `center` ({polygonId, depth}) is an edge pixel against its four
-- orthogonal neighbors (each {polygonId, depth} or nil for off-screen).
function DsEdgeMarking.isEdgePixel(center, up, down, left, right)
  return qualifies(center, up) or qualifies(center, down) or qualifies(center, left) or qualifies(center, right)
end

return DsEdgeMarking
