-- Splits coarse terrain boundary edges at shared breakpoints so separately
-- rendered material batches of one terrain model agree on boundary
-- segmentation.
--
-- Two terrain batches of one model can meet along one geometric span while
-- breaking it at different interior vertices (a T-junction): a coarse batch
-- carries boundary edge A-B while a touching batch owns boundary vertices
-- strictly inside that span, or one batch turns its own boundary at a vertex
-- its spanning edge does not express. Host triangle point-sampling can then
-- disagree along the two collinear but differently segmented edges and leave
-- an isolated sample owned by neither side. This module collects the union
-- of such breakpoints across every batch of the model and splits the coarse
-- boundary topology before mesh serialization, without merging materials,
-- batches, or render state.
--
-- The input is the CompiledBatch list from MeshCompiler.compile in model
-- tile units; conformance mutates that list in place and returns it. Only
-- the map/neighbor terrain roles route through here (see
-- ModelAssetCompiler); actors, buildings, and indicators bypass repair.
-- Processing order is fully deterministic (stable batch order, canonical
-- edge keys, parametric split order), so identical input serializes
-- byte-identically.

local Errors = require("libs.errors.src.Errors")

local TerrainBoundaryConformer = {}

-- Maximum perpendicular distance, in tiles, at which a touching batch's
-- boundary vertex still counts as collinear with a boundary edge. Exact
-- shared coordinates stay bit-identical through compilation, so genuine
-- breakpoints evaluate at (or near) zero distance; the margin only absorbs
-- floating-point rounding. Points 1e-3 tiles off the edge are rejected.
TerrainBoundaryConformer.COLLINEARITY_TOLERANCE_TILES = 1e-9

local TOLERANCE = TerrainBoundaryConformer.COLLINEARITY_TOLERANCE_TILES

-- Exact position identity for endpoint deduplication: 17 significant digits
-- distinguish every double, so bit-identical coordinates share a key while
-- merely close coordinates never do.
local function positionKey(x, y, z)
  return string.format("%.17g %.17g %.17g", x, y, z)
end

local function edgeKey(ka, kb)
  if ka <= kb then
    return ka .. "|" .. kb
  end
  return kb .. "|" .. ka
end

---@class TerrainBoundaryEdge
---@field triangle integer 1-based triangle position in the batch index list
---@field ia integer 1-based vertex index of the edge start
---@field ib integer 1-based vertex index of the edge end
---@field key string canonical geometric edge key

---@class TerrainBoundaryAnalysis
---@field edges TerrainBoundaryEdge[] boundary edges in canonical-key order
---@field boundaryPoints { x: number, y: number, z: number, key: string }[] unique boundary positions in key order

-- Boundary edges are geometric edges occurring exactly once in the batch;
-- internal tessellation edges occur twice and malformed counts are left
-- alone rather than repaired by guesswork.
---@param batch table
---@return TerrainBoundaryAnalysis
local function analyzeBatch(batch)
  assert(
    type(batch) == "table" and type(batch.vertices) == "table" and type(batch.indices) == "table",
    "conformance requires compiled batches with vertices and indices"
  )
  local triCount = math.floor(#batch.indices / 3)
  local counts = {}
  local first = {}
  local slots = {}
  for ti = 1, triCount do
    local i0 = batch.indices[(ti - 1) * 3 + 1]
    local i1 = batch.indices[(ti - 1) * 3 + 2]
    local i2 = batch.indices[(ti - 1) * 3 + 3]
    local v0 = batch.vertices[i0 + 1]
    local v1 = batch.vertices[i1 + 1]
    local v2 = batch.vertices[i2 + 1]
    assert(v0 ~= nil and v1 ~= nil and v2 ~= nil, "batch indices reference missing vertices")
    local keys = {}
    local ends = {
      { v0, i0, v1, i1 },
      { v1, i1, v2, i2 },
      { v2, i2, v0, i0 },
    }
    for _, pair in ipairs(ends) do
      local key = edgeKey(positionKey(pair[1].x, pair[1].y, pair[1].z), positionKey(pair[3].x, pair[3].y, pair[3].z))
      counts[key] = (counts[key] or 0) + 1
      if first[key] == nil then
        first[key] = { triangle = ti, ia = pair[2] + 1, ib = pair[4] + 1 }
      end
      keys[#keys + 1] = key
    end
    slots[ti] = keys
  end
  local edges = {}
  local seen = {}
  for ti = 1, triCount do
    for _, key in ipairs(slots[ti]) do
      if counts[key] == 1 and not seen[key] then
        seen[key] = true
        local rep = first[key]
        edges[#edges + 1] = { triangle = rep.triangle, ia = rep.ia, ib = rep.ib, key = key }
      end
    end
  end
  table.sort(edges, function(a, b)
    return a.key < b.key
  end)
  local boundaryPoints = {}
  local pointSeen = {}
  for _, edge in ipairs(edges) do
    for _, vi in ipairs({ edge.ia, edge.ib }) do
      local v = batch.vertices[vi]
      local key = positionKey(v.x, v.y, v.z)
      if not pointSeen[key] then
        pointSeen[key] = true
        boundaryPoints[#boundaryPoints + 1] = { x = v.x, y = v.y, z = v.z, key = key }
      end
    end
  end
  table.sort(boundaryPoints, function(a, b)
    return a.key < b.key
  end)
  return { edges = edges, boundaryPoints = boundaryPoints }
end

-- Parametric position of P along A-B, or nil when P is not a strictly
-- interior collinear point: endpoints, off-segment projections, points
-- beyond tolerance off the line, and points at/near either endpoint never
-- split.
local function splitParam(ax, ay, az, bx, by, bz, px, py, pz)
  if px == ax and py == ay and pz == az then
    return nil
  end
  if px == bx and py == by and pz == bz then
    return nil
  end
  local abx, aby, abz = bx - ax, by - ay, bz - az
  local apx, apy, apz = px - ax, py - ay, pz - az
  local len2 = abx * abx + aby * aby + abz * abz
  if len2 == 0 then
    return nil
  end
  local t = (apx * abx + apy * aby + apz * abz) / len2
  if t <= 0 or t >= 1 then
    return nil
  end
  local cx = apy * abz - apz * aby
  local cy = apz * abx - apx * abz
  local cz = apx * aby - apy * abx
  if (cx * cx + cy * cy + cz * cz) / len2 > TOLERANCE * TOLERANCE then
    return nil
  end
  if apx * apx + apy * apy + apz * apz <= TOLERANCE * TOLERANCE then
    return nil
  end
  local bpx, bpy, bpz = px - bx, py - by, pz - bz
  if bpx * bpx + bpy * bpy + bpz * bpz <= TOLERANCE * TOLERANCE then
    return nil
  end
  return t
end

---@class TerrainBoundaryEvent
---@field batchIndex integer
---@field candidateBatch integer
---@field edge TerrainBoundaryEdge
---@field t number
---@field x number
---@field y number
---@field z number
---@field key string

-- Every (batch, boundary edge, boundary vertex) triple where the vertex lies
-- strictly inside the edge. Candidates come from every batch's boundary in
-- the model, including the edge's own batch: separately rendered batches can
-- share a span, but one batch can equally break its own boundary span at a
-- vertex the spanning edge does not express (a corner where the boundary
-- turns, or a chord across same-batch segments), and host sampling disagrees
-- along such pairs regardless of batch ownership. Interior tessellation
-- vertices are never candidates. Generation order is deterministic: stable
-- batch order, canonical edge order, stable candidate order, keyed point
-- order.
---@param batches table[]
---@param analyses TerrainBoundaryAnalysis[]
---@return TerrainBoundaryEvent[]
local function collectEvents(batches, analyses)
  local events = {}
  for i, batch in ipairs(batches) do
    local analysis = analyses[i]
    for _, edge in ipairs(analysis.edges) do
      local va = batch.vertices[edge.ia]
      local vb = batch.vertices[edge.ib]
      for j, _ in ipairs(batches) do
        for _, point in ipairs(analyses[j].boundaryPoints) do
          local t = splitParam(va.x, va.y, va.z, vb.x, vb.y, vb.z, point.x, point.y, point.z)
          if t ~= nil then
            events[#events + 1] = {
              batchIndex = i,
              candidateBatch = j,
              edge = edge,
              t = t,
              x = point.x,
              y = point.y,
              z = point.z,
              key = point.key,
            }
          end
        end
      end
    end
  end
  return events
end

---@class TerrainBoundaryDiagnostic
---@field batchIndex integer
---@field materialIndex integer|nil
---@field edgeStart { x: number, y: number, z: number }
---@field edgeEnd { x: number, y: number, z: number }
---@field candidateBatch integer
---@field candidateMaterial integer|nil
---@field position { x: number, y: number, z: number }

-- Pure inspection helper: every unmatched boundary T-junction, cross-batch or
-- same-batch, sorted by batch, edge, candidate, and position. Empty after
-- conformance.
---@param batches table[]
---@return TerrainBoundaryDiagnostic[]
function TerrainBoundaryConformer.findTJunctions(batches)
  assert(type(batches) == "table", "findTJunctions requires a compiled batch list")
  local analyses = {}
  for i, batch in ipairs(batches) do
    analyses[i] = analyzeBatch(batch)
  end
  local diagnostics = {}
  for _, event in ipairs(collectEvents(batches, analyses)) do
    local batch = batches[event.batchIndex]
    local other = batches[event.candidateBatch]
    local va = batch.vertices[event.edge.ia]
    local vb = batch.vertices[event.edge.ib]
    diagnostics[#diagnostics + 1] = {
      batchIndex = event.batchIndex,
      materialIndex = batch.materialIndex,
      edgeStart = { x = va.x, y = va.y, z = va.z },
      edgeEnd = { x = vb.x, y = vb.y, z = vb.z },
      candidateBatch = event.candidateBatch,
      candidateMaterial = other.materialIndex,
      position = { x = event.x, y = event.y, z = event.z },
    }
  end
  return diagnostics
end

local function lerp(a, b, t)
  return a + t * (b - a)
end

local function lerpByte(a, b, t)
  local v = math.floor(lerp(a, b, t) + 0.5)
  if v < 0 then
    return 0
  end
  if v > 255 then
    return 255
  end
  return v
end

-- The inserted vertex belongs to the coarse batch: position is copied
-- exactly from the shared breakpoint, u/v and normals interpolate in the
-- batch's stored domains, and byte colors interpolate with deterministic
-- rounding. colorSource is categorical and resolved by the caller.
local function interpolateRecord(va, vb, t, px, py, pz)
  return {
    x = px,
    y = py,
    z = pz,
    u = lerp(va.u, vb.u, t),
    v = lerp(va.v, vb.v, t),
    nx = lerp(va.nx, vb.nx, t),
    ny = lerp(va.ny, vb.ny, t),
    nz = lerp(va.nz, vb.nz, t),
    r = lerpByte(va.r, vb.r, t),
    g = lerpByte(va.g, vb.g, t),
    b = lerpByte(va.b, vb.b, t),
    a = lerpByte(va.a, vb.a, t),
    colorSource = va.colorSource,
  }
end

local function conformErrorContext(context, batchIndex, batch, va, vb)
  local out = { batchIndex = batchIndex }
  if type(context) == "table" then
    for _, key in ipairs({ "mapId", "mapSymbol", "role", "modelArchive", "modelMemberId", "modelName" }) do
      local value = context[key]
      if value ~= nil then
        out[key] = value
      end
    end
  end
  out.materialIndex = batch.materialIndex
  out.edgeStart = { x = va.x, y = va.y, z = va.z }
  out.edgeEnd = { x = vb.x, y = vb.y, z = vb.z }
  out.colorSourceA = va.colorSource
  out.colorSourceB = vb.colorSource
  return out
end

---@class TerrainSplitItem
---@field ia0 integer 0-based index of the original edge start
---@field ib0 integer 0-based index of the original edge end
---@field breaks { t: number, record: table }[] inserted points in parametric order

-- Splits the owning triangle of each boundary subsegment in turn. Every
-- split replaces one triangle with two strict sub-triangles, so winding,
-- area, and the partition property hold by construction; the next
-- subsegment's owner is always the unique triangle holding both endpoints.
---@param batch table
---@param items TerrainSplitItem[]
local function applyItems(batch, items)
  if #items == 0 then
    return
  end
  local tris = {}
  for ti = 1, math.floor(#batch.indices / 3) do
    tris[ti] = { batch.indices[(ti - 1) * 3 + 1], batch.indices[(ti - 1) * 3 + 2], batch.indices[(ti - 1) * 3 + 3] }
  end
  for _, item in ipairs(items) do
    local start = item.ia0
    for _, br in ipairs(item.breaks) do
      batch.vertices[#batch.vertices + 1] = br.record
      local p = #batch.vertices - 1
      local owner = nil
      for oi, tri in ipairs(tris) do
        local hasStart = tri[1] == start or tri[2] == start or tri[3] == start
        local hasEnd = tri[1] == item.ib0 or tri[2] == item.ib0 or tri[3] == item.ib0
        if hasStart and hasEnd then
          owner = oi
          break
        end
      end
      assert(owner ~= nil, "a boundary subsegment always has exactly one owning triangle")
      local tri = tris[owner]
      local first, second
      if (tri[1] == start or tri[1] == item.ib0) and (tri[2] == start or tri[2] == item.ib0) then
        first = { tri[1], p, tri[3] }
        second = { p, tri[2], tri[3] }
      elseif (tri[2] == start or tri[2] == item.ib0) and (tri[3] == start or tri[3] == item.ib0) then
        first = { tri[2], p, tri[1] }
        second = { p, tri[3], tri[1] }
      else
        first = { tri[3], p, tri[2] }
        second = { p, tri[1], tri[2] }
      end
      tris[owner] = first
      table.insert(tris, owner + 1, second)
      start = p
    end
  end
  local flat = {}
  for _, tri in ipairs(tris) do
    flat[#flat + 1] = tri[1]
    flat[#flat + 1] = tri[2]
    flat[#flat + 1] = tri[3]
  end
  batch.indices = flat
end

-- Repairs every collected T-junction: each coarse boundary span gains the
-- union of touching breakpoints, both sides express the same positions, and
-- batches without junctions are left untouched. Returns the same list.
---@param batches table[]
---@param context table|nil map/model/role source context for producer errors
---@return table[]
function TerrainBoundaryConformer.conform(batches, context)
  assert(type(batches) == "table", "conform requires a compiled batch list")
  local analyses = {}
  for i, batch in ipairs(batches) do
    analyses[i] = analyzeBatch(batch)
  end
  -- Group events per (batch, edge), deduplicating identical positions so
  -- one span with n internal breakpoints becomes n+1 boundary segments.
  local plans = {}
  local planned = {}
  for _, event in ipairs(collectEvents(batches, analyses)) do
    local group = event.batchIndex .. "|" .. event.edge.key .. "|" .. event.key
    if planned[group] == nil then
      planned[group] = true
      local list = plans[event.batchIndex]
      if list == nil then
        list = {}
        plans[event.batchIndex] = list
      end
      local entry = nil
      for _, candidate in ipairs(list) do
        if candidate.edge.key == event.edge.key then
          entry = candidate
          break
        end
      end
      if entry == nil then
        entry = { edge = event.edge, breaks = {} }
        list[#list + 1] = entry
      end
      entry.breaks[#entry.breaks + 1] = event
    end
  end
  -- Resolve every inserted record before mutating anything, so a
  -- categorical conflict fails before partial repair.
  local itemsByBatch = {}
  for i = 1, #batches do
    local list = plans[i]
    if list ~= nil then
      table.sort(list, function(a, b)
        return a.edge.key < b.edge.key
      end)
      local batch = batches[i]
      local items = {}
      for _, entry in ipairs(list) do
        table.sort(entry.breaks, function(a, b)
          if a.t ~= b.t then
            return a.t < b.t
          end
          return a.key < b.key
        end)
        local va = batch.vertices[entry.edge.ia]
        local vb = batch.vertices[entry.edge.ib]
        if va.colorSource ~= vb.colorSource then
          Errors.raise(
            "MAP_COMPILE_TERRAIN_BOUNDARY_COLOR_SOURCE_CONFLICT",
            "terrain boundary edge endpoints disagree on colorSource ("
              .. tostring(va.colorSource)
              .. " ~= "
              .. tostring(vb.colorSource)
              .. "); cannot interpolate the inserted vertex",
            conformErrorContext(context, i, batch, va, vb)
          )
        end
        local breaks = {}
        for _, br in ipairs(entry.breaks) do
          breaks[#breaks + 1] = { t = br.t, record = interpolateRecord(va, vb, br.t, br.x, br.y, br.z) }
        end
        items[#items + 1] = { ia0 = entry.edge.ia - 1, ib0 = entry.edge.ib - 1, breaks = breaks }
      end
      itemsByBatch[i] = items
    end
  end
  for i = 1, #batches do
    local items = itemsByBatch[i]
    if items ~= nil then
      applyItems(batches[i], items)
    end
  end
  return batches
end

return TerrainBoundaryConformer
