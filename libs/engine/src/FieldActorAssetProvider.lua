-- Runtime owner of compiled field-actor visuals. It loads a sprite's definition
-- and atlas from the derived cache on first acquire, hands out one shared entry
-- per spriteId while it is referenced, and releases LÖVE resources on the last
-- release (or, for a bounded number of recently-used entries, on eviction). It
-- is the only module that turns generated actor data into LÖVE objects; nothing
-- above it may hold an Image directly.
--
-- Every load is fatal on a missing or malformed artifact: a target map must
-- never silently fall back to a placeholder visual.

local Errors = require("libs.rom.src.Errors")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldActorMesh = require("libs.engine.src.FieldActorMesh")

local FieldActorAssetProvider = {}
FieldActorAssetProvider.__index = FieldActorAssetProvider

local DEFAULT_IDLE_LIMIT = 8

-- opts.idleLimit: how many unreferenced entries stay resident before the least
-- recently released one is disposed. opts.graphics: injectable LÖVE graphics
-- namespace, so headless tests can drive the whole lifecycle.
function FieldActorAssetProvider.new(cacheFs, opts)
  assert(cacheFs, "FieldActorAssetProvider requires a CacheFs")
  opts = opts or {}
  local index = FieldActorCache.loadIndex(cacheFs)
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    Errors.raise("FIELD_ACTOR_INDEX_UNAVAILABLE",
      "no compiled field-actor index at " .. FieldActorCache.indexPath(),
      { path = FieldActorCache.indexPath() })
  end
  local known = {}
  for _, spriteId in ipairs(index.spriteIds) do known[spriteId] = true end

  return setmetatable({
    _cacheFs = cacheFs,
    _index = index,
    _known = known,
    _graphics = opts.graphics or (love and love.graphics),
    _idleLimit = opts.idleLimit or DEFAULT_IDLE_LIMIT,
    _entries = {},
    _idle = {}, -- least-recently-released first
    _stats = { loads = 0, hits = 0, disposals = 0, evictions = 0 },
  }, FieldActorAssetProvider)
end

function FieldActorAssetProvider:index() return self._index end

function FieldActorAssetProvider:knows(spriteId) return self._known[spriteId] == true end

-- The resident entry for a referenced sprite, without touching its reference
-- count: the draw path reads what the actor set already acquired.
function FieldActorAssetProvider:resident(spriteId) return self._entries[spriteId] end

local function removeIdle(self, spriteId)
  for i, id in ipairs(self._idle) do
    if id == spriteId then table.remove(self._idle, i) return end
  end
end

local function disposeEntry(self, entry)
  if entry.image and entry.image.release then entry.image:release() end
  FieldActorMesh.release(entry.meshes)
  entry.image, entry.meshes = nil, nil
  self._entries[entry.spriteId] = nil
  self._stats.disposals = self._stats.disposals + 1
end

-- Build one quad per atlas frame. Quads are pure geometry over the strip, so a
-- pose lookup is an index, never a rectangle computation at draw time.
local function buildQuads(self, visual, imageWidth, imageHeight)
  local newQuad = self._graphics and self._graphics.newQuad
  if not newQuad then return nil end
  local quads = {}
  for i = 1, visual.render.frameCount do
    quads[i] = newQuad((i - 1) * visual.render.frameWidth, 0,
      visual.render.frameWidth, visual.render.frameHeight, imageWidth, imageHeight)
  end
  return quads
end

local function load(self, spriteId)
  local visual = self._cacheFs:loadLua(FieldActorCache.visualPath(spriteId))
  if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA then
    Errors.raise("FIELD_ACTOR_VISUAL_UNAVAILABLE",
      "no " .. FieldActorCache.SCHEMA .. " definition for spriteId " .. spriteId,
      { spriteId = spriteId, path = FieldActorCache.visualPath(spriteId) })
  end

  local entry = { spriteId = spriteId, visual = visual, references = 0 }
  if self._graphics then
    local data = self._cacheFs:read(visual.render.image)
    if not data then
      Errors.raise("FIELD_ACTOR_ATLAS_MISSING",
        "atlas missing for spriteId " .. spriteId .. ": " .. visual.render.image,
        { spriteId = spriteId, path = visual.render.image })
    end
    entry.image = self._graphics.newImage(
      love.filesystem.newFileData(data, visual.render.image))
    -- DS textures are point-sampled; anything else fringes the cutout edges.
    entry.image:setFilter("nearest", "nearest")
    entry.quads = buildQuads(self, visual, entry.image:getWidth(), entry.image:getHeight())
  end
  -- The world billboard meshes are independent of the atlas Image, so headless
  -- callers with a mesh-capable graphics stub still get them.
  entry.meshes = FieldActorMesh.build(self._graphics, visual)
  self._stats.loads = self._stats.loads + 1
  return entry
end

-- Acquire a shared visual. Every acquire must be matched by exactly one release.
function FieldActorAssetProvider:acquire(spriteId)
  if not self._known[spriteId] then
    Errors.raise("FIELD_ACTOR_SPRITE_NOT_COMPILED",
      "spriteId " .. tostring(spriteId) .. " is not in the compiled actor set",
      { spriteId = spriteId })
  end
  local entry = self._entries[spriteId]
  if entry then
    self._stats.hits = self._stats.hits + 1
    if entry.references == 0 then removeIdle(self, spriteId) end
  else
    entry = load(self, spriteId)
    self._entries[spriteId] = entry
  end
  entry.references = entry.references + 1
  return entry
end

function FieldActorAssetProvider:release(spriteId)
  local entry = self._entries[spriteId]
  if not entry then
    Errors.raise("FIELD_ACTOR_RELEASE_UNKNOWN",
      "released spriteId " .. tostring(spriteId) .. ", which is not resident",
      { spriteId = spriteId })
  end
  if entry.references == 0 then
    Errors.raise("FIELD_ACTOR_RELEASE_UNBALANCED",
      "released spriteId " .. spriteId .. " more times than it was acquired",
      { spriteId = spriteId })
  end
  entry.references = entry.references - 1
  if entry.references > 0 then return end

  self._idle[#self._idle + 1] = spriteId
  while #self._idle > self._idleLimit do
    local evicted = table.remove(self._idle, 1)
    self._stats.evictions = self._stats.evictions + 1
    disposeEntry(self, self._entries[evicted])
  end
end

function FieldActorAssetProvider:stats()
  local live, references = 0, 0
  for _, entry in pairs(self._entries) do
    live = live + 1
    references = references + entry.references
  end
  return {
    loads = self._stats.loads,
    hits = self._stats.hits,
    disposals = self._stats.disposals,
    evictions = self._stats.evictions,
    live = live,
    references = references,
    idle = #self._idle,
  }
end

function FieldActorAssetProvider:dispose()
  for _, entry in pairs(self._entries) do
    if entry.image and entry.image.release then entry.image:release() end
    FieldActorMesh.release(entry.meshes)
    self._stats.disposals = self._stats.disposals + 1
  end
  self._entries = {}
  self._idle = {}
end

return FieldActorAssetProvider
