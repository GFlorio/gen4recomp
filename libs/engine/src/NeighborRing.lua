-- Optional presentation-only ring of the eight matrix cells surrounding a
-- central map cell. plan() is pure: given a decoded MapMatrix, the centre cell,
-- and a header->area resolver, it returns the neighbour cells to draw -- each
-- with its exact 32-tile world offset, decoded map-header id, land-data member,
-- and resolved area member -- plus the deduplicated set of land members so the
-- loader compiles/instances each unique chunk once. Out-of-bounds cells are
-- skipped without wrapping; cells whose header has no checked-in area mapping
-- are skipped too. load() (the love/ROM-coupled half) lives below and builds the
-- GPU draws from this plan. Neighbours are additive: with the feature disabled
-- nothing is planned and the central scene is untouched.

local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.engine.src.FieldGrid")
local NeighborChunkCompiler = require("libs.assets.src.NeighborChunkCompiler")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")

local NeighborRing = {}

-- The eight surrounding cells in a deterministic row-major order so the planned
-- list (and every downstream draw list) is stable.
local OFFSETS = {
  { dx = -1, dz = -1 }, { dx = 0, dz = -1 }, { dx = 1, dz = -1 },
  { dx = -1, dz = 0 }, { dx = 1, dz = 0 },
  { dx = -1, dz = 1 }, { dx = 0, dz = 1 }, { dx = 1, dz = 1 },
}

local TILES_PER_CELL = FieldGrid.CELL_TILES

local function inBounds(matrix, x, z)
  return x >= 0 and z >= 0 and x < matrix.width and z < matrix.height
end

-- Pure plan of the neighbour ring around cell (cx, cz). `areaForHeader` maps a
-- decoded map-header id to an area-data member id (or nil to skip the cell).
function NeighborRing.plan(matrix, cx, cz, areaForHeader)
  local cells = {}
  local uniqueSet = {}
  for _, off in ipairs(OFFSETS) do
    local x, z = cx + off.dx, cz + off.dz
    if inBounds(matrix, x, z) then
      local cell = matrix:cell(x, z)
      local area = areaForHeader(cell.mapHeaderId)
      if area ~= nil then
        cells[#cells + 1] = {
          x = x,
          z = z,
          dx = off.dx,
          dz = off.dz,
          offsetTilesX = off.dx * TILES_PER_CELL,
          offsetTilesZ = off.dz * TILES_PER_CELL,
          mapHeaderId = cell.mapHeaderId,
          landDataMemberId = cell.landDataMemberId,
          areaDataMemberId = area,
        }
        uniqueSet[cell.landDataMemberId] = true
      end
    end
  end

  local uniqueLandMembers = {}
  for member in pairs(uniqueSet) do uniqueLandMembers[#uniqueLandMembers + 1] = member end
  table.sort(uniqueLandMembers)

  return { cells = cells, uniqueLandMembers = uniqueLandMembers }
end

-- Parse the content-address out of a compiler-produced geometry path.
local function meshSha1(geometryPath)
  return assert(geometryPath:match("([0-9a-f]+)%.g4mesh$"), "unexpected geometry path " .. geometryPath)
end

local function textureSha1(texturePath)
  return texturePath and texturePath:match("([0-9a-f]+)%.png$") or nil
end

-- Build (or fetch from the shared cache) a persistent love Mesh for a compiled
-- batch, deduplicated across every chunk by its content hash. The cache keeps
-- the decoded vertices too, for the sort-center computation.
local function meshEntry(sha1, compiled, meshCache, owned)
  local entry = meshCache[sha1]
  if not entry then
    local decoded = SceneMesh.decode(MeshWriter.encode(compiled.meshes[sha1]))
    entry = { mesh = SceneMesh.build(decoded), verts = decoded.vertices }
    meshCache[sha1] = entry
    owned.meshes[#owned.meshes + 1] = entry.mesh
  end
  return entry
end

-- Build (or fetch) a persistent love Image for a decoded texture, deduplicated
-- across chunks by content hash. Returns the image with the material's wrap set.
local function imageFor(sha1, compiled, imageCache, owned)
  if not sha1 then return nil end
  local image = imageCache[sha1]
  if not image then
    local tex = compiled.textures[sha1]
    local data = love.image.newImageData(tex.width, tex.height, "rgba8", tex.pixels)
    image = love.graphics.newImage(data)
    image:setFilter("nearest", "nearest")
    imageCache[sha1] = image
    owned.images[#owned.images + 1] = image
  end
  return image
end

local function materialsById(compiled, imageCache, owned)
  local byId = {}
  for _, m in ipairs(compiled.materials) do
    local image = imageFor(textureSha1(m.texture), compiled, imageCache, owned)
    if image then
      local function mode(w) return w == "repeat" and "repeat" or "clamp" end
      local wrap = m.wrap or { x = "clamp", y = "clamp" }
      image:setWrap(mode(wrap.x), mode(wrap.y))
    end
    local d = m.diffuse or { r = 255, g = 255, b = 255, a = 255 }
    byId[m.id] = {
      id = m.id,
      name = m.name,
      image = image,
      diffuse = { d.r / 255, d.g / 255, d.b / 255, d.a / 255 },
    }
  end
  return byId
end

local function modelCenter(verts)
  local minx, miny, minz = math.huge, math.huge, math.huge
  local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
  for _, v in ipairs(verts) do
    minx = math.min(minx, v[1]); maxx = math.max(maxx, v[1])
    miny = math.min(miny, v[2]); maxy = math.max(maxy, v[2])
    minz = math.min(minz, v[3]); maxz = math.max(maxz, v[3])
  end
  return { (minx + maxx) / 2, (miny + maxy) / 2, (minz + maxz) / 2 }
end

-- Load the planned neighbour ring into GPU draw items. `romFs` is an open RomFs;
-- neighbours are terrain-only and read the ROM directly (they are outside the
-- per-map derived cache). Returns { draws, stats, release }.
function NeighborRing.load(romFs, plan)
  local meshCache, imageCache = {}, {}
  local owned = { meshes = {}, images = {} }

  -- Compile each unique land member's terrain chunk once, then wrap it into a
  -- reusable set of draw templates (mesh + material + render state + center).
  local chunkByMember = {}
  for _, member in ipairs(plan.uniqueLandMembers) do
    -- Every cell using this land member shares one area (same header), so the
    -- first matching cell's area is representative.
    local areaMemberId
    for _, cell in ipairs(plan.cells) do
      if cell.landDataMemberId == member then areaMemberId = cell.areaDataMemberId break end
    end
    local compiled = NeighborChunkCompiler.compile(romFs, member, areaMemberId)
    local materials = materialsById(compiled, imageCache, owned)

    local templates = {}
    for _, batch in ipairs(compiled.batches) do
      local entry = meshEntry(meshSha1(batch.geometry), compiled, meshCache, owned)
      templates[#templates + 1] = {
        mesh = entry.mesh,
        material = materials[batch.material],
        alphaClass = batch.alphaClass or "opaque",
        cullMode = batch.cullMode or "back",
        alphaCutoff = 0.5 / 255,
        polygonAlpha = batch.polygonAlpha ~= nil and (batch.polygonAlpha / 31) or 1.0,
        polygonMode = batch.polygonMode or "modulation",
        lightMask = batch.lightMask or 0,
        polygonId = batch.polygonId or 0,
        translucentDepthWrite = batch.translucentDepthWrite or false,
        depthEqual = batch.depthEqual or false,
        center = modelCenter(entry.verts),
      }
    end
    chunkByMember[member] = templates
  end

  -- One draw per (cell, batch), with the cell's 32-tile world offset baked into
  -- the transform and the sort center.
  local draws = {}
  local submission = 200000 -- behind the diagnostic overlays' index space
  for _, cell in ipairs(plan.cells) do
    local ox, oz = cell.offsetTilesX, cell.offsetTilesZ
    local transform = Matrix4.translate(ox, 0, oz)
    for _, t in ipairs(chunkByMember[cell.landDataMemberId] or {}) do
      submission = submission + 1
      draws[#draws + 1] = {
        mesh = t.mesh,
        material = t.material,
        transform = transform,
        alphaClass = t.alphaClass,
        cullMode = t.cullMode,
        alphaCutoff = t.alphaCutoff,
        polygonAlpha = t.polygonAlpha,
        polygonMode = t.polygonMode,
        lightMask = t.lightMask,
        polygonId = t.polygonId,
        translucentDepthWrite = t.translucentDepthWrite,
        depthEqual = t.depthEqual,
        center = { t.center[1] + ox, t.center[2], t.center[3] + oz },
        submissionIndex = submission,
      }
    end
  end

  local ring = {
    draws = draws,
    stats = {
      cellCount = #plan.cells,
      chunkCount = #plan.uniqueLandMembers,
      meshCount = #owned.meshes,
      textureCount = #owned.images,
    },
  }
  function ring:release()
    for _, mesh in ipairs(owned.meshes) do mesh:release() end
    for _, image in ipairs(owned.images) do image:release() end
    owned.meshes, owned.images = {}, {}
  end
  return ring
end

return NeighborRing
