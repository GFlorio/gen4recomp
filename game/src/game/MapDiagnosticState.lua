-- Interactive diagnostic state: render a compiled map in 3D and traverse it with
-- a debug player. It reads the derived cache through MapSceneLoader (a cold cache
-- is a hard error -- build it first), builds one persistent MapRenderer,
-- and spawns a DebugPlayer on the map's provisional tile. WASD steps the player
-- one tile per press through the permission grid. The camera is fixed at the
-- map's field angle (from the camera profile) and simply follows the player --
-- no orbit or zoom. A project-generated prism marks the player and yellow pins
-- mark the development coordinate anchors. All GPU objects are built once here;
-- draw only issues the renderer pass (with the player/anchor overlays) and a 2D
-- HUD. A load failure is captured as text rather than crashing the window.

local CacheFs = require("libs.rom.src.CacheFs")
local MapCatalog = require("libs.assets.src.MapCatalog")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")
local MapRenderer = require("libs.engine.src.MapRenderer")
local Camera3D = require("libs.engine.src.Camera3D")
local Gizmos = require("libs.engine.src.Gizmos")
local Matrix4 = require("libs.math.src.Matrix4")
local FieldGrid = require("libs.engine.src.FieldGrid")
local DebugPlayer = require("libs.engine.src.DebugPlayer")
local NeighborRing = require("libs.engine.src.NeighborRing")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local CameraProfiles = require("data.manifests.camera_profiles")
local TargetAnchors = require("data.manifests.target_map_anchors")

local MapDiagnosticState = {}
MapDiagnosticState.__index = MapDiagnosticState

local MOVE_KEYS = { w = "north", s = "south", a = "west", d = "east" }

-- Tab cycles the diagnostic between the two vertical-slice targets. The list is
-- symbol-based (not a member-id heuristic) so the switch reads as a map identity.
local SWITCH_TARGETS = { "MAP_NEW_BARK_ELMS_LAB_1F", "MAP_NEW_BARK" }

-- Fixed camera distance (tile units) for the field preview. 26 matches the
-- renderer's edge-marking reference distance, so outlines carry their DS-relative
-- weight at the default framing.
local DEFAULT_DISTANCE = 26

function MapDiagnosticState.new(versionId, idOrSymbol)
  local envTime = os.getenv("G4RECOMP_FIELD_TIME")
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or "MAP_NEW_BARK_ELMS_LAB_1F",
    errorText = nil,
    fieldTimeSeconds = envTime and tonumber(envTime) or FieldLightProfile.DEFAULT_TIME_SECONDS,
  }, MapDiagnosticState)
  self:_load()
  return self
end

function MapDiagnosticState:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)

    local map = MapCatalog.require(self.idOrSymbol)
    local mapDir = MapAssetCache.mapDir(map.id)
    if not cacheFs:read(mapDir .. "/scene.lua") then
      error("map cache is cold — run `love romdump/ --build` first")
    end
    local scene = assert(cacheFs:loadLua(mapDir .. "/scene.lua"), "scene.lua missing")
    self.runtime = MapSceneLoader.load(cacheFs, scene)
    self.runtime.fieldTimeSeconds = self.fieldTimeSeconds
    self.renderer = MapRenderer.new()

    -- Debug player at the map's provisional spawn (validated at construction),
    -- plus its prism and the anchor pins.
    self.target = TargetAnchors[scene.mapSymbol] or {}
    self.player = DebugPlayer.new(self.runtime.collision, self.target.spawn)
    self.anchors = self.target.anchors or {}
    self.playerMesh = Gizmos.box(0.35, 0, 1.6, 0.35, { 0.95, 0.25, 0.25, 1 })
    self.anchorMesh = Gizmos.box(0.12, 0, 2.4, 0.12, { 1.0, 0.85, 0.1, 1 })
    self.playerMat = { alphaClass = "opaque", cullMode = "back" }
    self.anchorMat = { alphaClass = "opaque", cullMode = "back" }

    self:_setupCamera()
    self:_applyShotOverrides()

    -- Presentation-only neighbor ring around the current cell. Naturally a no-op
    -- for the 1x1 Elm's Lab matrix (every neighbor is out of bounds).
    self:_loadNeighbors()
  end)
  if not ok then
    self.errorText = tostring(err)
    io.stderr:write("map-diagnostic load failed: " .. self.errorText .. "\n")
  end
end

-- Smoke-mode camera overrides so an automated capture can inspect the scene from
-- a different angle/distance than the fixed field framing.
function MapDiagnosticState:_applyShotOverrides()
  if not os.getenv("G4RECOMP_SHOT") then return end
  local yaw = tonumber(os.getenv("G4RECOMP_SHOT_YAW"))
  local pitch = tonumber(os.getenv("G4RECOMP_SHOT_PITCH"))
  local dist = tonumber(os.getenv("G4RECOMP_SHOT_DIST"))
  local target = os.getenv("G4RECOMP_SHOT_TARGET") -- "worldX,worldZ"
  if yaw then self.camera.yaw = math.rad(yaw) end
  if pitch then self.camera.pitch = math.rad(pitch) end
  if dist then self.camera.distance = dist end
  if target then
    local tx, tz = target:match("^%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)%s*$")
    assert(tx, "G4RECOMP_SHOT_TARGET must be 'worldX,worldZ'")
    self.camera.target = { tonumber(tx), self.camera.target[2], tonumber(tz) }
  end
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

-- Fixed field camera: seed the angle and lens from the map's camera profile,
-- lock the distance, and aim at the player.
function MapDiagnosticState:_setupCamera()
  local profile = CameraProfiles[self.runtime.cameraType] or {}
  self.camera = Camera3D.fromProfile(profile, { 0, 0, 0 }, self:_aspect())
  self.camera.distance = DEFAULT_DISTANCE
  self:_followPlayer()
end

-- Aim the camera at the player's tile (flat Y). Called on load and after each step.
function MapDiagnosticState:_followPlayer()
  local x, y, z = self:_playerWorld()
  self.camera.target = { x, y + 0.5, z }
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

-- Env-gated switch stress: after a short warmup, toggle between the two targets
-- once per frame for G4RECOMP_SWITCH_CYCLES iterations, releasing and rebuilding
-- all GPU objects each time. Any failed load exits nonzero; completing every
-- switch exits zero. Automated proof that repeated switching is stable/leak-free.
function MapDiagnosticState:_maybeSwitchStress()
  local n = tonumber(os.getenv("G4RECOMP_SWITCH_CYCLES") or "")
  if not n then return end
  self._switchStep = (self._switchStep or -3) + 1 -- warmup frames before the first switch
  if self._switchStep <= 0 then return end
  if self.errorText then
    io.stderr:write("switch-stress: FAIL on load: " .. self.errorText .. "\n")
    return love.event.quit(1)
  end
  if self._switchStep > n then
    print(string.format("switch-stress: OK (%d switches, ended on %s)", n, self.runtime.scene.mapSymbol))
    return love.event.quit(0)
  end
  self:_cycleMap()
end

function MapDiagnosticState:update()
  self:_maybeSwitchStress()
  self:_maybeCaptureAndQuit()
end

-- Build the per-frame overlay draw list: the player prism plus one anchor pin
-- per development anchor. Transforms are cheap tables; the meshes are persistent.
function MapDiagnosticState:_overlays()
  local px, py, pz = self:_playerWorld()
  local list = {
    {
      mesh = self.playerMesh,
      material = self.playerMat,
      transform = Matrix4.translate(px, py, pz),
      center = { 0, 0.8, 0 },
      submissionIndex = 100000,
    },
  }
  for i, a in ipairs(self.anchors) do
    local ax, az = FieldGrid.tileCenterToWorld(a.localX, a.localZ)
    list[#list + 1] = {
      mesh = self.anchorMesh,
      material = self.anchorMat,
      transform = Matrix4.translate(ax, 0, az),
      center = { 0, 1.2, 0 },
      submissionIndex = 100000 + i,
    }
  end
  -- Neighbor-ring terrain draws (each already carries its 32-tile world offset
  -- transform and render state); they classify/depth-sort like any scene draw.
  if self.neighborRing then
    for _, d in ipairs(self.neighborRing.draws) do list[#list + 1] = d end
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
  local rt = self.runtime
  local scene = rt.scene
  local m = scene.matrix
  local area = scene.area
  local src = scene.source
  local ps = self.player:status()

  local lines = {
    string.format("%s  rom %s", self.versionId, (src.romSha1 or "?"):sub(1, 8)),
    string.format("map %d  %s  %q", scene.mapId, scene.mapSymbol, scene.label),
    string.format("matrix %d %q  %dx%d  cell (%d,%d)  index %d",
      m.memberId, m.name, m.width or 0, m.height or 0, m.x, m.z, m.index or (m.z * (m.width or 0) + m.x)),
    string.format("land member %d   origin (%d,%d)", src.landData.memberId, m.worldOriginX, m.worldOriginZ),
    string.format("area %d  %s  mapTex %d  bldTex %d  light %d",
      area.memberId, area.type, area.mapTexturePackId, area.buildingTexturePackId, area.lightType),
    string.format("camera type %d", scene.cameraType),
    string.format("player local (%d,%d) global (%d,%d) facing %s  y=%.1f",
      ps.localX, ps.localZ, ps.globalX, ps.globalZ, ps.facing, ps.y),
    string.format("under player: behavior 0x%02X  perm 0x%02X  block %s  response %d",
      ps.behavior, ps.permissionRaw, tostring(ps.hardBlocked), ps.terrainResponseId),
  }
  if self.neighborRing and self.neighborRing.stats.cellCount > 0 then
    local ns = self.neighborRing.stats
    lines[#lines + 1] = string.format("neighbors: %d cells  %d chunks", ns.cellCount, ns.chunkCount)
  elseif self.neighborError then
    lines[#lines + 1] = "neighbors: load failed (see stderr)"
  end
  if ps.spawnFallback then
    lines[#lines + 1] = string.format("spawn relocated from (%d,%d) to nearest passable",
      self.player.requestedSpawn.x, self.player.requestedSpawn.z)
  end
  for _, a in ipairs(self.anchors) do
    local g = a.globalX and string.format(" global (%d,%d)", a.globalX, a.globalZ) or ""
    lines[#lines + 1] = string.format("anchor [dev]: %s @ local (%d,%d)%s", a.label, a.localX, a.localZ, g)
  end
  lines[#lines + 1] = "limitations: flat Y (no BDHC height), approximate camera"
  lines[#lines + 1] = "WASD move   Tab switch map   Q/E hour   Esc quit"

  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 640, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for i, line in ipairs(lines) do lg.print(line, 20, 12 + (i - 1) * 20) end
end

function MapDiagnosticState:keypressed(key)
  if key == "escape" then
    love.event.quit(0)
    return
  end
  if key == "tab" then
    self:_cycleMap()
    return
  end
  if not self.runtime then return end
  local dir = MOVE_KEYS[key]
  if dir then
    self.player:tryStep(dir)
    self:_followPlayer()
  elseif key == "q" or key == "pageup" then
    self.fieldTimeSeconds = (self.fieldTimeSeconds - 3600) % 86400
    self.runtime.fieldTimeSeconds = self.fieldTimeSeconds
  elseif key == "e" or key == "pagedown" then
    self.fieldTimeSeconds = (self.fieldTimeSeconds + 3600) % 86400
    self.runtime.fieldTimeSeconds = self.fieldTimeSeconds
  end
end

-- Release every GPU object this state owns (renderer canvases/shaders, the
-- runtime's meshes/textures, and the overlay gizmo meshes) and drop the handles.
-- Used both on shutdown and before switching maps so a switch cannot leak or
-- keep stale GPU objects around.
function MapDiagnosticState:_releaseGpu()
  self:_releaseNeighbors()
  if self.renderer then self.renderer:release() end
  if self.runtime then self.runtime:release() end
  if self.playerMesh then self.playerMesh:release() end
  if self.anchorMesh then self.anchorMesh:release() end
  self.renderer, self.runtime = nil, nil
  self.playerMesh, self.anchorMesh = nil, nil
end

function MapDiagnosticState:_releaseNeighbors()
  if self.neighborRing then self.neighborRing:release() end
  self.neighborRing = nil
end

-- Build the neighbor ring for the current map: re-decode its matrix from the raw
-- dump (the scene only carries the centre cell), plan the eight surrounding
-- cells, and compile/instance their terrain. Reads the ROM directly (neighbours
-- live outside the per-map derived cache); a failure is captured, not fatal.
function MapDiagnosticState:_loadNeighbors()
  self:_releaseNeighbors()
  local romFs
  local ok, ringOrErr = pcall(function()
    local RomFs = require("libs.rom.src.RomFs")
    local MapMatrix = require("libs.assets.src.MapMatrix")
    local m = self.runtime.scene.matrix
    romFs = assert(RomFs.open(self.versionId))
    local matrixBytes = assert(assert(romFs:openNarc("map_matrices")):readMember(m.memberId))
    local matrix = assert(MapMatrix.decode(matrixBytes, self.runtime.scene.mapId))
    local plan = NeighborRing.plan(matrix, m.x, m.z, function(headerId)
      local rec = MapCatalog.areaForMapHeader(headerId)
      return rec and rec.areaDataMemberId or nil
    end)
    return NeighborRing.load(romFs, plan)
  end)
  if romFs then romFs:close() end
  if ok then
    self.neighborRing = ringOrErr
    self.neighborError = nil
  else
    self.neighborError = tostring(ringOrErr)
    io.stderr:write("neighbor-ring load failed: " .. self.neighborError .. "\n")
  end
end

-- Tear the current map down and load another target from scratch. Field time is
-- preserved so the lighting/HUD state carries across; everything else (camera,
-- player, meshes) is rebuilt by _load for the new scene.
function MapDiagnosticState:_switchTo(idOrSymbol)
  self:_releaseGpu()
  self.idOrSymbol = idOrSymbol
  self.errorText = nil
  self:_load()
end

-- Cycle to the next vertical-slice target (Elm's Lab <-> New Bark).
function MapDiagnosticState:_cycleMap()
  local current = self.runtime and self.runtime.scene.mapSymbol or MapCatalog.require(self.idOrSymbol).symbol
  local at = 1
  for i, sym in ipairs(SWITCH_TARGETS) do
    if sym == current then at = i break end
  end
  self:_switchTo(SWITCH_TARGETS[at % #SWITCH_TARGETS + 1])
end

function MapDiagnosticState:quit()
  self:_releaseGpu()
end

return MapDiagnosticState
