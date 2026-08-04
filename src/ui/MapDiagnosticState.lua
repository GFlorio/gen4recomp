-- Interactive Gate 6 state: render Elm's Lab (or any compiled map) in 3D. It
-- loads the derived cache through MapSceneLoader, compiling on demand in this
-- developer path when the map is not yet built, then builds one persistent
-- MapRenderer. A free orbit camera (drag to orbit, wheel to zoom, arrows to
-- pan, R to reframe, C to toggle the provisional game-camera angle) lets a human
-- confirm geometry, textures, placed models, and depth ordering. GPU objects are
-- created once here; draw only issues the renderer pass and a 2D HUD whose
-- constant mesh/texture counts show there is no per-frame resource leak. A load
-- failure is captured as text rather than crashing the window.

local CacheFs = require("src.import.CacheFs")
local MapCatalog = require("src.data.MapCatalog")
local MapAssetCache = require("src.core.MapAssetCache")
local MapSceneLoader = require("src.world.MapSceneLoader")
local MapRenderer = require("src.render.MapRenderer")
local Camera3D = require("src.render.Camera3D")
local CameraProfiles = require("data.manifests.camera_profiles")

local MapDiagnosticState = {}
MapDiagnosticState.__index = MapDiagnosticState

function MapDiagnosticState.new(versionId, idOrSymbol)
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or "MAP_NEW_BARK_ELMS_LAB_1F",
    errorText = nil,
    dragging = false,
  }, MapDiagnosticState)
  self:_load()
  return self
end

-- Compile the target map into the derived cache if it is not already present.
-- Developer-path only: ordinary runtime would show a compile screen instead.
local function ensureCompiled(versionId, cacheFs, idOrSymbol)
  local map = MapCatalog.require(idOrSymbol)
  local scenePath = MapAssetCache.mapDir(map.id) .. "/scene.lua"
  if cacheFs:read(scenePath) then return end

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
end

function MapDiagnosticState:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    ensureCompiled(self.versionId, cacheFs, self.idOrSymbol)

    local map = MapCatalog.require(self.idOrSymbol)
    local scene = assert(cacheFs:loadLua(MapAssetCache.mapDir(map.id) .. "/scene.lua"),
      "scene.lua missing after compile")
    self.runtime = MapSceneLoader.load(cacheFs, scene)
    self.renderer = MapRenderer.new()
    self.camera = Camera3D.new({ aspect = self:_aspect() })
    self:_resetCamera()
    -- Smoke-mode camera-angle overrides so an automated capture can inspect the
    -- scene from more than the default framing.
    if os.getenv("G4RECOMP_SHOT") then
      local yaw = tonumber(os.getenv("G4RECOMP_SHOT_YAW"))
      local pitch = tonumber(os.getenv("G4RECOMP_SHOT_PITCH"))
      if yaw then self.camera.yaw = math.rad(yaw) end
      if pitch then self.camera.pitch = math.rad(pitch) end
    end
  end)
  if not ok then
    self.errorText = tostring(err)
    io.stderr:write("map-diagnostic load failed: " .. self.errorText .. "\n")
  end
end

function MapDiagnosticState:_aspect()
  if not love.graphics then return 1 end
  local w, h = love.graphics.getDimensions()
  return h > 0 and w / h or 1
end

-- Frame the whole scene: target its center, back off far enough for the bounds
-- radius to fit the vertical field of view, seed the angle from the profile.
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
  self.useProfileAngle = true
end

-- Env-gated render smoke: when G4RECOMP_SHOT names a save-dir-relative path, let
-- a few frames warm up, capture the framebuffer once, and quit. This lets the
-- otherwise human-only visual gate be checked automatically (CI/agent) without
-- someone watching the window.
function MapDiagnosticState:_maybeCaptureAndQuit()
  local path = os.getenv("G4RECOMP_SHOT")
  if not path then return end
  self._frames = (self._frames or 0) + 1
  if self._frames == 8 then
    love.graphics.captureScreenshot(path) -- captures this frame (also the error screen)
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

function MapDiagnosticState:draw()
  local lg = love.graphics
  if self.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Map render failed:", 24, 24)
    lg.printf(self.errorText, 24, 48, lg.getWidth() - 48)
    return
  end

  self.camera:setAspect(self:_aspect())
  self.renderer:draw(self.runtime, self.camera)

  -- 2D HUD (renderer restored all state on the way out).
  local s = self.renderer.stats
  local rt = self.runtime
  local lines = {
    string.format("%s  (map %d, %s)", rt.label, rt.mapId, self.versionId),
    string.format("camera type %d  yaw %.0f  pitch %.0f  dist %.1f",
      rt.cameraType, math.deg(self.camera.yaw), math.deg(self.camera.pitch), self.camera.distance),
    string.format("draw calls %d   triangles %d", s.drawCalls, s.triangles),
    string.format("meshes %d   textures %d   building instances %d",
      s.meshCount, s.textureCount, rt.stats.buildingInstances),
    "drag: orbit   wheel: zoom   arrows: orbit   R: reframe   Esc: quit",
  }
  lg.setColor(0, 0, 0, 0.5)
  lg.rectangle("fill", 12, 12, 520, 20 * #lines + 12)
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
  elseif key == "r" and self.runtime then
    self:_resetCamera()
  end
end

function MapDiagnosticState:quit()
  if self.renderer then self.renderer:release() end
  if self.runtime then self.runtime:release() end
end

return MapDiagnosticState
