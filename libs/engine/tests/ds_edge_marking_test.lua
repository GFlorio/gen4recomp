-- Tests for the DS edge-marking predicate reference: same/different
-- polygon ID against the four orthogonal neighbors, the strict depth-in-front
-- gate, missing (off-screen) neighbors, and the edge-color table index.

local Assert = require("tests.support.Assert")
local DsEdgeMarking = require("libs.engine.src.DsEdgeMarking")

local T = {}

local function px(polygonId, depth)
  return { polygonId = polygonId, depth = depth }
end

function T.table_index_is_polygon_id_shifted_right_by_3()
  Assert.equal(DsEdgeMarking.edgeTableIndex(0), 0)
  Assert.equal(DsEdgeMarking.edgeTableIndex(7), 0)
  Assert.equal(DsEdgeMarking.edgeTableIndex(8), 1)
  Assert.equal(DsEdgeMarking.edgeTableIndex(63), 7)
end

function T.table_index_exhaustive_matches_shift()
  for id = 0, 63 do
    Assert.equal(DsEdgeMarking.edgeTableIndex(id), math.floor(id / 8), "id=" .. id)
  end
end

function T.no_edge_when_all_neighbors_share_polygon_id()
  local center = px(3, 100)
  local same = px(3, 50) -- closer, but same ID: still not an edge
  Assert.isFalse(DsEdgeMarking.isEdgePixel(center, same, same, same, same))
end

function T.no_edge_when_different_id_but_center_not_in_front()
  -- Center is farther (larger depth) than the differently-ID'd neighbor, so
  -- the center is not strictly in front and must not be marked.
  local center = px(3, 200)
  local farNeighbor = px(4, 100)
  Assert.isFalse(DsEdgeMarking.isEdgePixel(center, farNeighbor, farNeighbor, farNeighbor, farNeighbor))
end

function T.no_edge_when_different_id_but_depths_equal()
  -- Coplanar boundary: different IDs, same depth -- not strictly in front.
  local center = px(3, 100)
  local neighbor = px(4, 100)
  Assert.isFalse(DsEdgeMarking.isEdgePixel(center, neighbor, neighbor, neighbor, neighbor))
end

function T.edge_when_different_id_and_center_strictly_in_front()
  local center = px(3, 100)
  local neighbor = px(4, 200)
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, neighbor, neighbor, neighbor, neighbor))
end

-- Only one of the four orthogonal neighbors needs to satisfy the predicate.
function T.edge_when_only_one_of_four_neighbors_qualifies()
  local center = px(3, 100)
  local same = px(3, 50)
  local qualifying = px(9, 500)
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, qualifying, same, same, same), "up")
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, same, qualifying, same, same), "down")
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, same, same, qualifying, same), "left")
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, same, same, same, qualifying), "right")
end

-- A diagonal-only difference must never be consulted: the predicate takes
-- exactly four orthogonal neighbors, never eight.
function T.missing_neighbor_off_screen_contributes_no_edge()
  local center = px(3, 100)
  Assert.isFalse(DsEdgeMarking.isEdgePixel(center, nil, nil, nil, nil))
end

function T.missing_neighbors_mixed_with_one_qualifying()
  local center = px(3, 100)
  local qualifying = px(9, 500)
  Assert.isTrue(DsEdgeMarking.isEdgePixel(center, qualifying, nil, nil, nil))
  Assert.isFalse(DsEdgeMarking.isEdgePixel(center, nil, nil, nil, nil))
end

return { tests = T }
