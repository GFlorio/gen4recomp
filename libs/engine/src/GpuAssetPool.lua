-- The one shared GPU-asset owner for scene loading: MapSceneLoader and
-- NeighborRing both need "read content-addressed cache bytes, decode/build a
-- persistent love Mesh, and build a persistent love Image per unique sampler
-- state", so this pool is that shared responsibility. It dedups meshes by
-- content-addressed path and images by path plus wrap X/Y (two materials
-- sharing pixels but sampling them differently never alias one mutable
-- sampler), owns every object it creates, releases them exactly once, and
-- releases everything already acquired when a later acquire fails. The filter
-- is currently uniform (nearest), so it stays out of the image key; if it
-- ever varies, it belongs in the key too. The pool knows nothing about maps,
-- neighbors, materials, bounds, or transforms; those stay in the loaders.

local SceneMesh = require("libs.engine.src.SceneMesh")
local Errors = require("libs.rom.src.Errors")

---@class GpuAssetPool
---@field cacheFs table
---@field graphics love.Graphics
---@field meshes love.Mesh[]
---@field images love.Image[]
---@field triangles integer
local GpuAssetPool = {}
GpuAssetPool.__index = GpuAssetPool

local WRAP_MODES = { clamp = true, ["repeat"] = true }

-- Run an acquire under protection: any failure releases everything the pool
-- already owns before the error propagates, so a partially failed load can
-- never leak GPU objects.
local function guarded(pool, fn)
  local ok, err = pcall(fn)
  if not ok then
    pool:release()
    error(err)
  end
end

-- cacheFs: a CacheFs-shaped reader (read(path) returns raw bytes or nil);
-- opts.graphics: injectable LÖVE graphics namespace (nil keeps love.graphics).
---@param cacheFs table
---@param opts { graphics?: love.Graphics? }?
---@return GpuAssetPool
function GpuAssetPool.new(cacheFs, opts)
  assert(cacheFs and cacheFs.read, "GpuAssetPool requires a CacheFs-shaped object")
  opts = opts or {}
  return setmetatable({
    cacheFs = cacheFs,
    graphics = opts.graphics or (love and love.graphics),
    meshes = {},
    images = {},
    triangles = 0,
    _meshCache = {},
    _imageCache = {},
  }, GpuAssetPool)
end

-- Acquire (or fetch) the shared Mesh for a content-addressed geometry path.
-- Returns { mesh, verts, triangles }; the decoded vertices stay for sort
-- centers and the triangle count feeds loader stats exactly once per mesh.
---@param path string
---@return { mesh: love.Mesh, verts: table, triangles: number }
function GpuAssetPool:meshFor(path)
  local entry = self._meshCache[path]
  if not entry then
    guarded(self, function()
      local decoded = SceneMesh.decode(assert(self.cacheFs:read(path), "missing mesh " .. path), path)
      local mesh = SceneMesh.build(decoded)
      entry = { mesh = mesh, verts = decoded.vertices, triangles = decoded.indexCount / 3 }
      self._meshCache[path] = entry
      self.meshes[#self.meshes + 1] = mesh
      self.triangles = self.triangles + entry.triangles
    end)
  end
  return entry
end

-- Acquire (or fetch) the shared Image for a texture path under one immutable
-- sampler state (wrap X/Y). The image identity is the path plus the wrap
-- pair, so each distinct wrap pair owns its own configured Image. Unknown
-- wrap modes on a sampled material are malformed data and raise instead of
-- degrading to clamp; a nil path (untextured material, no sampler state)
-- yields no image. Any failure here releases every object the pool already
-- owns before the error propagates.
---@param path string?
---@param wrapX string
---@param wrapY string
---@return love.Image?
function GpuAssetPool:imageFor(path, wrapX, wrapY)
  if not path then
    return nil
  end
  local byWrap = self._imageCache[path]
  if not byWrap then
    byWrap = {}
    self._imageCache[path] = byWrap
  end
  local key = wrapX .. "|" .. wrapY
  local image = byWrap[key]
  if not image then
    guarded(self, function()
      if not WRAP_MODES[wrapX] or not WRAP_MODES[wrapY] then
        Errors.raise(
          "GPU_ASSET_UNKNOWN_WRAP",
          "unknown texture wrap mode " .. tostring(wrapX) .. "/" .. tostring(wrapY),
          { path = path, wrapX = wrapX, wrapY = wrapY }
        )
      end
      local bytes = assert(self.cacheFs:read(path), "missing texture " .. path)
      local data = love.filesystem.newFileData(bytes, "tex.png")
      image = self.graphics.newImage(data)
      image:setFilter("nearest", "nearest")
      image:setWrap(wrapX, wrapY)
      byWrap[key] = image
      self.images[#self.images + 1] = image
    end)
  end
  return image
end

-- Release every owned GPU object exactly once. Idempotent: the owned lists,
-- the dedup caches, and the triangle count are cleared, so a repeat release
-- (or a cleanup after a failed acquire) never touches the same object twice.
function GpuAssetPool:release()
  for _, mesh in ipairs(self.meshes) do
    mesh:release()
  end
  for _, image in ipairs(self.images) do
    image:release()
  end
  self.meshes, self.images = {}, {}
  self._meshCache, self._imageCache = {}, {}
  self.triangles = 0
end

return GpuAssetPool
