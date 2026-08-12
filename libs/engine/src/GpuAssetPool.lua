-- The one shared GPU-asset owner for scene loading: MapSceneLoader and
-- NeighborRing both need "read content-addressed cache bytes, decode/build a
-- persistent love Mesh, and build a persistent love Image per unique sampler
-- state", so this pool is that shared responsibility. It dedups meshes by
-- content-addressed path and images by path plus wrap X/Y (two materials
-- sharing pixels but sampling them differently never alias one mutable
-- sampler), and owns every object it creates. Failure has two scopes: a
-- construction wrapped in transaction() releases everything the construction
-- created (the loaders wrap their whole scene build in one), while a single
-- lazy acquire outside a transaction releases only the object that failed
-- acquisition itself created -- a failed variant load during live draw
-- evaluation never frees the resources the scene is drawing. The filter is
-- currently uniform (nearest), so it stays out of the image key; if it ever
-- varies, it belongs in the key too. The pool knows nothing about maps,
-- neighbors, materials, bounds, or transforms; those stay in the loaders.

local SceneMesh = require("libs.engine.src.SceneMesh")
local Errors = require("libs.errors.src.Errors")

---@class GpuAssetPool
---@field cacheFs table
---@field graphics love.Graphics
---@field meshBuilder fun(decoded: table): any
---@field imageBuilder fun(path: string): any|nil
---@field meshes love.Mesh[]
---@field images love.Image[]
---@field triangles integer
---@field _inTransaction boolean
local GpuAssetPool = {}
GpuAssetPool.__index = GpuAssetPool

local WRAP_MODES = { clamp = true, ["repeat"] = true }

-- Release the last object of an owned list -- the failed acquisition's own --
-- after `revert` undid its dedup-cache bookkeeping. The pop happens only when
-- a guarded body recorded an object before failing.
local function releaseLast(owned, revert)
  local object = owned[#owned]
  owned[#owned] = nil
  if revert then
    revert()
  end
  object:release()
end

-- Run an acquire under protection: any failure releases only the object the
-- failed acquisition itself created -- never objects from earlier acquisitions
-- or a live scene. The guarded body records at most one object (its owned-list
-- and dedup-cache entries) before any step that can fail; `revert` removes
-- that object's dedup-cache entry, and the owned-list pop plus the release
-- happen here. A body that fails before recording anything owns nothing.
local function guarded(pool, fn, revert)
  local imagesBefore = #pool.images
  local meshesBefore = #pool.meshes
  local ok, err = pcall(fn)
  if not ok then
    if #pool.images > imagesBefore then
      assert(#pool.meshes == meshesBefore, "a guarded acquire created a mesh and an image")
      releaseLast(pool.images, revert)
    elseif #pool.meshes > meshesBefore then
      releaseLast(pool.meshes, revert)
    end
    error(err)
  end
end

---@class GpuAssetPoolOptions
---@field graphics? love.Graphics -- injectable LÖVE graphics namespace (nil keeps love.graphics)
---@field meshBuilder? fun(decoded: table): any -- replaces SceneMesh.build (headless tests)
---@field imageBuilder? fun(path: string): any -- replaces love-graphics texture construction (headless tests)

-- cacheFs: a CacheFs-shaped reader (read(path) returns raw bytes or nil); see
-- GpuAssetPoolOptions for the injectable GPU seams. A builder image is
-- configured (filter/wrap) and owned exactly like a love-built one.
---@param cacheFs table
---@param opts GpuAssetPoolOptions?
---@return GpuAssetPool
function GpuAssetPool.new(cacheFs, opts)
  assert(cacheFs and cacheFs.read, "GpuAssetPool requires a CacheFs-shaped object")
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics and graphics.newImage, "GpuAssetPool requires love.graphics")
  return setmetatable({
    cacheFs = cacheFs,
    graphics = opts.graphics or (love and love.graphics),
    meshBuilder = opts.meshBuilder or SceneMesh.build,
    imageBuilder = opts.imageBuilder,
    meshes = {},
    images = {},
    triangles = 0,
    _meshCache = {},
    _imageCache = {},
    _inTransaction = false,
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
      local mesh = self.meshBuilder(decoded)
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
-- yields no image. A failure here releases only the image this acquisition
-- itself created -- the pool's other objects stay owned. The image is
-- recorded before it is configured, so a configuration failure pops exactly
-- its own cache entry and owned-list slot.
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
      local created
      if self.imageBuilder then
        created = self.imageBuilder(path)
      else
        local bytes = assert(self.cacheFs:read(path), "missing texture " .. path)
        local data = love.filesystem.newFileData(bytes, "tex.png")
        created = self.graphics.newImage(data)
      end
      byWrap[key] = created
      self.images[#self.images + 1] = created
      created:setFilter("nearest", "nearest")
      created:setWrap(wrapX, wrapY)
      image = created
    end, function()
      byWrap[key] = nil
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

-- Run `fn` as a construction transaction: the loaders wrap their whole scene
-- build in it. On failure everything the pool owns is released (the whole
-- construction rolls back, dedup caches included) and the failure re-raises;
-- on success everything stays owned and fn's value is returned. The
-- transaction is not release-on-exit, and nesting is rejected -- an inner
-- rollback would release the outer construction's objects.
---@param fn fun(): any
---@return any
function GpuAssetPool:transaction(fn)
  assert(type(fn) == "function", "GpuAssetPool:transaction requires a function")
  assert(not self._inTransaction, "GpuAssetPool:transaction is not nestable")
  self._inTransaction = true
  local ok, result = pcall(fn)
  self._inTransaction = false
  if not ok then
    self:release()
    error(result)
  end
  return result
end

return GpuAssetPool
