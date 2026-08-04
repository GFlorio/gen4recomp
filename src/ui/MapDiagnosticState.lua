-- Interactive diagnostic state: render a compiled map in 3D and traverse it with
-- a debug player. It loads the derived cache through MapSceneLoader (compiling on
-- demand in this developer path when cold), builds one persistent MapRenderer,
-- and spawns a DebugPlayer on the map's provisional tile. WASD steps the player
-- one tile per press through the permission grid; the camera follows the player
-- (C toggles free framing, R reframes the whole scene, drag/wheel/arrows orbit
-- and zoom). A project-generated prism marks the player and yellow pins mark the
-- development coordinate anchors. All GPU objects are built once here; draw only
-- issues the renderer pass (with the player/anchor overlays) and a 2D HUD whose
-- constant mesh/texture counts show there is no per-frame resource leak. A load
-- failure is captured as text rather than crashing the window.

local CacheFs = require("src.import.CacheFs")
local MapCatalog = require("src.data.MapCatalog")
local MapAssetCache = require("src.core.MapAssetCache")
local MapSceneLoader = require("src.world.MapSceneLoader")
local MapRenderer = require("src.render.MapRenderer")
local Camera3D = require("src.render.Camera3D")
local Gizmos = require("src.render.Gizmos")
local Matrix4 = require("src.render.Matrix4")
local FieldGrid = require("src.world.FieldGrid")
local DebugPlayer = require("src.world.DebugPlayer")
local CameraProfiles = require("data.manifests.camera_profiles")
local TargetAnchors = require("data.manifests.target_map_anchors")

local MapDiagnosticState = {}
MapDiagnosticState.__index = MapDiagnosticState

local MOVE_KEYS = { w = "north", s = "south", a = "west", d = "east" }

function MapDiagnosticState.new(versionId, idOrSymbol)
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or "MAP_NEW_BARK_ELMS_LAB_1F",
    errorText = nil,
    dragging = false,
    follow = true,
  }, MapDiagnosticState)
  self:_load()
  return self
end

-- Compile the target map into the derived cache if not already present. Returns
-- "hit" when the cache already had the scene (no ROM/NSBMD touched), "miss" when
-- it had to compile. Developer-path only.
local function ensureCompiled(versionId, cacheFs, idOrSymbol)
  local map = MapCatalog.require(idOrSymbol)
  local scenePath = MapAssetCache.mapDir(map.id) .. "/scene.lua"
  if cacheFs:read(scenePath) then return "hit" end

  local MapAssetCompiler = require("src.import.MapAssetCompiler")
  local MapCacheWriter = require("src.import.MapCacheWriter")
  local RomFs = require("src.core.RomFs")
  local romFs = assert(RomFs.open(versionId))
  local ok, bundle = pcall(MapAssetCompiler.compile, romFs, idOrSymbol)
  if ok and bundle then
    if not MapAssetCache.isReady(cacheFs, bundle.mapId, bundle.marker) then
      MapCacheWriter.write(cacheFs, bundle)
    end
  end
  romFs:close()
  if not ok then error(bundle) end
  return "miss"
end

function MapDiagnosticState:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.cacheStatus = ensureCompiled(self.versionId, cacheFs, self.idOrSymbol)

    local map = MapCatalog.require(self.idOrSymbol)
    local mapDir = MapAssetCache.mapDir(map.id)
    local scene = assert(cacheFs:loadLua(mapDir .. "/scene.lua"), "scene.lua missing after compile")
    self.runtime = MapSceneLoader.load(cacheFs, scene)
    self.renderer = MapRenderer.new()

    -- Dependency-hash prefix from the completion marker, for the HUD.
    local marker = cacheFs:read(mapDir .. "/complete") or ""
    self.depHash = marker:match(":([%x]+)$") or "?"

    -- Debug player at the map's provisional spawn (validated at construction),
    -- plus its prism and the anchor pins.
    self.target = TargetAnchors[scene.mapSymbol] or {}
    self.player = DebugPlayer.new(self.runtime.collision, self.target.spawn)
    self.anchors = self.target.anchors or {}
    self.playerMesh = Gizmos.box(0.35, 0, 1.6, 0.35)
    self.anchorMesh = Gizmos.box(0.12, 0, 2.4, 0.12)
    self.playerMat = { diffuse = { 0.95, 0.25, 0.25, 1 }, alphaMode = "opaque", cullMode = "back" }
    self.anchorMat = { diffuse = { 1.0, 0.85, 0.1, 1 }, alphaMode = "opaque", cullMode = "back" }

    self.camera = Camera3D.new({ aspect = self:_aspect() })
    self:_resetCamera()
    self:_centerOnPlayer()
    self:_applyShotOverrides()
  end)
  if not ok then
    self.errorText = tostring(err)
    io.stderr:write("map-diagnostic load failed: " .. self.errorText .. "\n")
  end
end

-- Smoke-mode camera-angle overrides so an automated capture can inspect the
-- scene from more than the default framing.
function MapDiagnosticState:_applyShotOverrides()
  if not os.getenv("G4RECOMP_SHOT") then return end
  local yaw = tonumber(os.getenv("G4RECOMP_SHOT_YAW"))
  local pitch = tonumber(os.getenv("G4RECOMP_SHOT_PITCH"))
  if yaw then self.camera.yaw = math.rad(yaw) end
  if pitch then self.camera.pitch = math.rad(pitch) end
end

function MapDiagnosticState:_aspect()
  if not love.graphics then return 1 end
  local w, h = love.graphics.getDimensions()
  return h > 0 and w / h or 1
end

-- World-space centre of the player's current tile (flat Y).
function MapDiagnosticState:_playerWorld()
  local x, z = FieldGrid.tileCenterToWorld(self.player.localX, self.player.localZ)
  return x, self.player.y, z
end

-- Frame the whole scene: target its center, back off far enough for the bounds
-- radius to fit the vertical field of view, seed the angle from the profile.
-- Leaves follow mode off so the free view holds until the player moves or R/C.
function MapDiagnosticState:_resetCamera()
  local b = self.runtime.bounds
  local profile = CameraProfiles[self.runtime.cameraType] or {}
  local seeded = Camera3D.fromProfile(profile, { b.center[1], b.center[2], b.center[3] }, self:_aspect())
  local ex = b.max[1] - b.min[1]
  local ey = b.max[2] - b.min[2]
  local ez = b.max[3] - b.min[3]
  local radius = math.max(ex, ey, ez) / 2
  seeded.distance = math.max(4, radius / math.tan(seeded.fovY / 2) * 1.3)
  self.camera = seeded
  self.follow = false
end

-- Point the current camera at the player (keeping yaw/pitch, moving to a closer
-- follow distance the first time) and enable follow.
function MapDiagnosticState:_centerOnPlayer()
  local x, y, z = self:_playerWorld()
  self.camera.target = { x, y + 0.5, z }
  if not self.follow then self.camera.distance = math.min(self.camera.distance, 14) end
  self.follow = true
end

-- Env-gated render smoke: when G4RECOMP_SHOT names a save-dir-relative path, let
-- a few frames warm up, capture the framebuffer once, and quit.
function MapDiagnosticState:_maybeCaptureAndQuit()
  local path = os.getenv("G4RECOMP_SHOT")
  if not path then return end
  self._frames = (self._frames or 0) + 1
  if self._frames == 8 then
    love.graphics.captureScreenshot(path)
  elseif self._frames >= 9 then
    love.event.quit(0)
  end
end

function MapDiagnosticState:update(dt)
  self:_maybeCaptureAndQuit()
  if self.errorText then return end
  local step = dt * 6
  local k = love.keyboard
  if k.isDown("left") then self.camera:orbit(-step, 0) end
  if k.isDown("right") then self.camera:orbit(step, 0) end
  if k.isDown("up") then self.camera:orbit(0, step) end
  if k.isDown("down") then self.camera:orbit(0, -step) end
end

-- Build the per-frame overlay draw list: the player prism plus one anchor pin
-- per development anchor. Transforms are cheap tables; the meshes are persistent.
function MapDiagnosticState:_overlays()
  local px, py, pz = self:_playerWorld()
  local list = { { mesh = self.playerMesh, material = self.playerMat, transform = Matrix4.translate(px, py, pz) } }
  for _, a in ipairs(self.anchors) do
    local ax, az = FieldGrid.tileCenterToWorld(a.localX, a.localZ)
    list[#list + 1] = { mesh = self.anchorMesh, material = self.anchorMat, transform = Matrix4.translate(ax, 0, az) }
  end
  return list
end

function MapDiagnosticState:draw()
  local lg = love.graphics
  if self.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Map render failed:", 24, 24)
    lg.printf(self.errorText, 24, 48, lg.getWidth() - 48)
    return
  end

  self.camera:setAspect(self:_aspect())
  self.renderer:draw(self.runtime, self.camera, self:_overlays())
  self:_drawHud()
end

function MapDiagnosticState:_drawHud()
  local lg = love.graphics
  local s = self.renderer.stats
  local rt = self.runtime
  local scene = rt.scene
  local m = scene.matrix
  local area = scene.area
  local src = scene.source
  local ps = self.player:status()

  local lines = {
    string.format("%s  rom %s  (%s)", self.versionId, (src.romSha1 or "?"):sub(1, 8),
      self.cacheStatus == "hit" and "cache hit" or "cache miss"),
    string.format("map %d  %s  %q", scene.mapId, scene.mapSymbol, scene.label),
    string.format("matrix %d %q  %dx%d  cell (%d,%d)  index %d",
      m.memberId, m.name, m.width or 0, m.height or 0, m.x, m.z, m.index or (m.z * (m.width or 0) + m.x)),
    string.format("land member %d   origin (%d,%d)", src.landData.memberId, m.worldOriginX, m.worldOriginZ),
    string.format("area %d  %s  mapTex %d  bldTex %d  light %d",
      area.memberId, area.type, area.mapTexturePackId, area.buildingTexturePackId, area.lightType),
    string.format("camera type %d  %s  yaw %.0f pitch %.0f dist %.1f",
      scene.cameraType, self.follow and "follow" or "free",
      math.deg(self.camera.yaw), math.deg(self.camera.pitch), self.camera.distance),
    string.format("map batches %d   buildings %d   meshes %d   textures %d",
      #(scene.mapBatches or {}), rt.stats.buildingInstances, s.meshCount, s.textureCount),
    string.format("triangles %d   draw calls %d   dep %s", s.triangles, s.drawCalls, self.depHash:sub(1, 8)),
    string.format("player local (%d,%d) global (%d,%d) facing %s  y=%.1f",
      ps.localX, ps.localZ, ps.globalX, ps.globalZ, ps.facing, ps.y),
    string.format("under player: behavior 0x%02X  perm 0x%02X  block %s  response %d",
      ps.behavior, ps.permissionRaw, tostring(ps.hardBlocked), ps.terrainResponseId),
  }
  if ps.spawnFallback then
    lines[#lines + 1] = string.format("spawn relocated from (%d,%d) to nearest passable",
      self.player.requestedSpawn.x, self.player.requestedSpawn.z)
  end
  for _, a in ipairs(self.anchors) do
    local g = a.globalX and string.format(" global (%d,%d)", a.globalX, a.globalZ) or ""
    lines[#lines + 1] = string.format("anchor [dev]: %s @ local (%d,%d)%s", a.label, a.localX, a.localZ, g)
  end
  lines[#lines + 1] = "limitations: flat Y (no BDHC height), approximate camera"
  lines[#lines + 1] = "WASD move   C follow/free   R reframe   drag/arrows orbit   wheel zoom   Esc quit"

  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 640, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for i, line in ipairs(lines) do lg.print(line, 20, 12 + (i - 1) * 20) end
end

function MapDiagnosticState:mousepressed(_, _, button)
  if button == 1 then self.dragging = true end
end

function MapDiagnosticState:mousereleased(_, _, button)
  if button == 1 then self.dragging = false end
end

function MapDiagnosticState:mousemoved(_, _, dx, dy)
  if self.dragging and self.camera then
    self.camera:orbit(dx * 0.01, -dy * 0.01)
  end
end

function MapDiagnosticState:wheelmoved(_, dy)
  if self.camera and dy ~= 0 then
    self.camera:zoom(dy > 0 and 0.9 or 1.1)
  end
end

function MapDiagnosticState:keypressed(key)
  if key == "escape" then
    love.event.quit(0)
    return
  end
  if not self.runtime then return end
  local dir = MOVE_KEYS[key]
  if dir then
    self.player:tryStep(dir)
    if self.follow then self:_centerOnPlayer() end
  elseif key == "r" then
    self:_resetCamera()
  elseif key == "c" then
    if self.follow then self.follow = false else self:_centerOnPlayer() end
  end
end

function MapDiagnosticState:quit()
  if self.renderer then self.renderer:release() end
  if self.runtime then self.runtime:release() end
  if self.playerMesh then self.playerMesh:release() end
  if self.anchorMesh then self.anchorMesh:release() end
end

return MapDiagnosticState
