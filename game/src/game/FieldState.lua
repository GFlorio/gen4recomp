-- Normal field-runtime coordinator. It joins generated maps through
-- FieldMapLoader, drives the deterministic elevation-aware player, and exposes
-- event/terrain debug overlays plus the field warp transition lifecycle.

local CacheFs = require("libs.rom.src.CacheFs")
local Errors = require("libs.rom.src.Errors")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldGrid = require("libs.engine.src.FieldGrid")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local FieldMapLoader = require("libs.engine.src.FieldMapLoader")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScenario = require("libs.engine.src.FieldScenario")
local FieldSaveStore = require("libs.engine.src.FieldSaveStore")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local Gizmos = require("libs.engine.src.Gizmos")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MapRenderer = require("libs.engine.src.MapRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local TargetAnchors = require("data.manifests.target_map_anchors")
local FieldActorManifest = require("data.manifests.field_actors")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldScenarioManifest = require("data.manifests.field_scenario")

local FieldState = {}
FieldState.__index = FieldState

local CAMERA_PROFILES_PATH = "data/generated/field/camera/profiles.lua"
local DEFAULT_MAP = "MAP_NEW_BARK_ELMS_LAB_1F"
local KEY_DIRECTIONS = {
  w = "north", up = "north",
  s = "south", down = "south",
  a = "west", left = "west",
  d = "east", right = "east",
}

local function initialSurface(runtimeMap, localX, localZ)
  local x, z = localX + 0.5, localZ + 0.5
  local best
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(x, z)) do
    local sample = runtimeMap.terrain:sample(plate.id, x, z)
    if not best or math.abs(sample.worldY) < math.abs(best.worldY)
      or (math.abs(sample.worldY) == math.abs(best.worldY) and sample.surfaceId < best.surfaceId) then
      best = sample
    end
  end
  assert(best, string.format("spawn tile (%d,%d) has no terrain surface", localX, localZ))
  return best
end

local function terrainEnvelope(terrain)
  local minY, maxY = math.huge, -math.huge
  for _, plate in ipairs(terrain.plates) do
    if plate.walkable ~= false then
      local corners = {
        { plate.minX, plate.minZ }, { plate.maxX, plate.minZ },
        { plate.maxX, plate.maxZ }, { plate.minX, plate.maxZ },
      }
      for _, point in ipairs(corners) do
        local y = terrain:sampleHeight(plate.id, point[1], point[2])
        minY, maxY = math.min(minY, y), math.max(maxY, y)
      end
    end
  end
  assert(minY <= maxY, "field terrain has no walkable height envelope")
  return { minY = minY, maxY = maxY }
end

function FieldState.new(versionId, idOrSymbol, options)
  options = options or {}
  local self = setmetatable({
    versionId = versionId,
    idOrSymbol = idOrSymbol or DEFAULT_MAP,
    resumeSave = options.resumeSave == true,
    resetSave = options.resetSave == true,
    -- Developer pins are off by default: normal play shows only the ROM-derived
    -- actors, never the placeholder prisms.
    overlaysVisible = false,
    errorText = nil,
    zoom = FieldZoom.new(options.zoomConfig or FieldPresentation.zoom),
  }, FieldState)
  self:_load()
  return self
end

function FieldState:_load()
  local ok, err = pcall(function()
    local cacheFs = CacheFs.forVersion(self.versionId)
    self.saveStore = FieldSaveStore.new(cacheFs)
    if self.resetSave then
      self.saveStore:reset()
      self.resetSave = false
      self.saveStatus = "Started a new field session"
    end
    local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()),
      "world.lua missing -- run `scripts/buildcache.sh` first")
    local profiles = assert(cacheFs:loadLua(CAMERA_PROFILES_PATH),
      "field camera cache is cold -- run `scripts/buildcache.sh` first")
    assert(profiles.schema == "g4-field-camera-profiles-v1", "unsupported field camera cache")
    self.cameraProfiles = profiles.profiles

    self.mapLoader = FieldMapLoader.new(cacheFs, world)
    local restored
    if self.resumeSave then
      local saved, saveErr = self.saveStore:load()
      if saved then
        restored, saveErr = FieldSave.restore(saved, self.mapLoader, self.versionId)
      end
      if saveErr and saveErr.code ~= "CACHE_FILE_MISSING" then
        self.saveStatus = "Save ignored: " .. tostring(saveErr)
        io.stderr:write("field save ignored: " .. tostring(saveErr) .. "\n")
      elseif restored then
        self.saveStatus = "Resumed saved field session"
      end
    end
    self.runtimeMap = restored and restored.runtimeMap or self.mapLoader:load(self.idOrSymbol)
    self.mapLoader:protectMap(self.runtimeMap.mapId, true)
    self.runtime = self.runtimeMap.sceneRuntime
    self.renderer = MapRenderer.new()

    local target = TargetAnchors[self.runtimeMap.mapSymbol] or {}
    local spawn = target.spawn or { x = 0, z = 0, facing = "south" }
    local fieldX, fieldZ, surfaceId, facing
    if restored then
      fieldX, fieldZ = restored.fieldX, restored.fieldZ
      surfaceId, facing = restored.surfaceId, restored.facing
    else
      fieldX, fieldZ = FieldCoordinates.localToField(self.runtimeMap, spawn.x, spawn.z)
      surfaceId, facing = initialSurface(self.runtimeMap, spawn.x, spawn.z).surfaceId, spawn.facing
    end
    self.player = FieldPlayer.new({
      currentMap = self.runtimeMap,
      fieldX = fieldX, fieldZ = fieldZ,
      surfaceId = surfaceId, facing = facing,
    })
    self.actor = self.player
    self.input = FieldInput.new()
    self.heldDirectionKeys = {}
    local worldPoint = self.player:renderPosition()

    local profile = assert(self.cameraProfiles[self.runtimeMap.cameraType],
      "field camera cache has no camera type " .. self.runtimeMap.cameraType)
    self.camera = FieldCamera.new(profile, { initialTarget = worldPoint })
    local width, height = love.graphics.getDimensions()
    self.viewport = FieldViewport.new(width, height, { mode = "expanded" })
    self:_updateCameraProjection()
    self.envelope = terrainEnvelope(self.runtimeMap.terrain)
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)

    -- The event store is rebuilt from the demo scenario on every boot until the
    -- save schema carries it; nothing persists event state yet.
    self.eventState = FieldEventState.new()
    self.scenarioApplied = FieldScenario.apply(FieldScenarioManifest, self.eventState,
      function(mapId) return cacheFs:loadLua(FieldMapDataCache.fieldPath(mapId)) end)
    self.actorAssets = FieldActorAssetProvider.new(cacheFs)
    self.actors = FieldActorManager.new({
      assets = self.actorAssets,
      policy = {
        variableSpriteRange = FieldActorManifest.variableSpriteRange,
        staticMovementCodes = FieldActorManifest.staticMovementCodes,
      },
      trace = function(record)
        io.stderr:write(string.format("%s %s sprite %d movement %d\n",
          record.kind, record.actorId, record.spriteId, record.movement))
      end,
    })
    self.actors:enterMap(self.runtimeMap, self.eventState)
    self.inspectorIndex = 0
    self.posePlaceholders = {}

    -- The player's graphic is one more compiled actor visual: it is acquired from
    -- the same reference-counted provider, and FieldPlayer keeps every bit of
    -- movement authority.
    self.avatar = FieldScenario.avatar(FieldScenarioManifest, FieldActorManifest.avatars)
    self.avatarAsset = self.actorAssets:acquire(self.avatar.spriteId)
    self.playerVisual = FieldPlayerVisual.new({
      player = self.player,
      spriteId = self.avatar.spriteId,
      visualDef = self.avatarAsset.visual,
    })

    self.transition = FieldTransition.new({
      loader = self.mapLoader,
      swap = function(resolution, facing) self:_swapMap(resolution, facing) end,
    })
    self.transition.suppression = restored and restored.suppression or nil
    self.session = FieldSession.new({
      versionId = self.versionId,
      currentMap = self.runtimeMap,
      actor = self.actor,
      player = self.player,
      camera = self.camera,
      transition = self.transition,
      actors = self.actors,
      playerVisual = self.playerVisual,
      input = self.input,
      coverage = function()
        self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
      end,
    })

    self.playerMesh = Gizmos.box(0.35, 0, 1.6, 0.35, { 0.95, 0.25, 0.25, 1 })
    self.actorMesh = Gizmos.box(0.30, 0, 1.6, 0.30, { 0.35, 0.9, 0.45, 1 })
    self.eventMesh = Gizmos.box(0.10, 0, 1.9, 0.10, { 1.0, 0.85, 0.1, 1 })
    self.terrainMesh = Gizmos.box(0.08, 0, 1.2, 0.08, { 0.2, 0.75, 1.0, 1 })
    self.playerMaterial = { alphaClass = "opaque", cullMode = "back" }
    self.eventMaterial = { alphaClass = "opaque", cullMode = "back" }
    self.terrainMaterial = { alphaClass = "opaque", cullMode = "back" }
  end)
  if not ok then
    self.errorText = tostring(err)
    self:_release()
    io.stderr:write("field-state load failed: " .. self.errorText .. "\n")
  end
end

function FieldState:update(dt)
  if self.session then
    -- A developer flag toggle can make an actor unresolvable on the next tick;
    -- report it in the field HUD instead of dropping to the LÖVE error screen.
    local ok, err = pcall(self.session.update, self.session, dt)
    if not ok then self.errorText = Errors.format(err) end
    if self.transition.error then
      local warp = self.transition.sourceWarp
      self.errorText = string.format("%s\nsource map %s warp %s -> map %s warp %s",
        tostring(self.transition.error), tostring(self.transition.sourceMap.mapId),
        tostring(warp.index), tostring(warp.destinationMapId),
        tostring(warp.destinationWarpId))
    end
    if self.transition:consumeCompleted() then self:_save("Autosaved after warp") end
  end
  self:_maybeRunSmoke()
end

function FieldState:_maybeRunSmoke()
  if not os.getenv("G4RECOMP_FIELD_SMOKE") then return end
  if self.errorText then
    io.stderr:write("field-smoke: " .. self.errorText .. "\n")
    love.event.quit(1)
    return
  end
  self._smokeFrame = (self._smokeFrame or 0) + 1
  if self._smokeFrame == 8 then
    local missing = self.runtimeMap.coveragePlan.missingVisibleCells or {}
    if #missing > 0 then
      io.stderr:write(string.format("field-smoke: %d visible cells are missing\n", #missing))
      love.event.quit(1)
      return
    end
    local path = os.getenv("G4RECOMP_SHOT")
    if path then love.graphics.captureScreenshot(path) end
  elseif self._smokeFrame >= 9 then
    love.event.quit(0)
  end
end

function FieldState:_save(successText)
  if not self.session or not FieldSave.canCapture(self.session) then
    self.saveStatus = "Save deferred: movement or transition is active"
    return false
  end
  local ok, err = pcall(function()
    self.saveStore:save(FieldSave.capture(self.session))
  end)
  if not ok then
    self.saveStatus = "Save failed: " .. tostring(err)
    io.stderr:write("field save failed: " .. tostring(err) .. "\n")
    return false
  end
  self.saveStatus = successText or "Field session saved"
  return true
end

function FieldState:_reset()
  local ok, err = pcall(function() self.saveStore:reset() end)
  if not ok then
    self.saveStatus = "Reset failed: " .. tostring(err)
    return
  end
  self:_release()
  self.session, self.transition, self.camera, self.player, self.actor = nil, nil, nil, nil, nil
  self.runtimeMap, self.runtime, self.viewport, self.saveStore = nil, nil, nil, nil
  self.resumeSave = false
  self.errorText = nil
  self.saveStatus = "Field session reset"
  self:_load()
end

function FieldState:_swapMap(resolution, facing)
  assert(self.transition.fadeAlpha == 1, "field map swap must be hidden by fade")
  local runtimeMap = resolution.destinationMap
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = resolution.fieldX,
    fieldZ = resolution.fieldZ,
    surfaceId = resolution.surfaceId,
    facing = facing,
  })
  local profile = assert(self.cameraProfiles[runtimeMap.cameraType],
    "field camera cache has no camera type " .. runtimeMap.cameraType)
  local camera = FieldCamera.new(profile, { initialTarget = player:renderPosition() })
  camera:setProjectionAspect(self.viewport:worldAspect())
  camera:setZoom(self.zoom:effectiveZoom())

  local previousMapId = self.runtimeMap.mapId
  self.actors:enterMap(runtimeMap, self.eventState)
  if runtimeMap.mapId ~= previousMapId then self.actors:leaveMap(previousMapId) end
  self.inspectorIndex = 0

  self.runtimeMap = runtimeMap
  self.runtime = runtimeMap.sceneRuntime
  self.player = player
  self.actor = player
  self.playerVisual = FieldPlayerVisual.new({
    player = player,
    spriteId = self.avatar.spriteId,
    visualDef = self.avatarAsset.visual,
  })
  self.session.playerVisual = self.playerVisual
  self.camera = camera
  self.envelope = terrainEnvelope(runtimeMap.terrain)
  self.session.currentMap = runtimeMap
  self.session.player = player
  self.session.actor = player
  self.session.camera = camera
  self.mapLoader:updateCoverage(runtimeMap, camera, self.envelope)
end

function FieldState:_updateCameraProjection()
  self.zoom:resize(self.viewport.worldViewport.height)
  self.camera:setProjectionAspect(self.viewport:worldAspect())
  self.camera:setZoom(self.zoom:effectiveZoom())
end

function FieldState:_applyZoomChange()
  self:_updateCameraProjection()
  self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
end

local function append(list, draw)
  draw.submissionIndex = 100000 + #list
  list[#list + 1] = draw
end

function FieldState:_eventPoint(event)
  local ok, point = pcall(FieldCoordinates.fieldToWorld,
    self.runtimeMap, event.x, event.z, (event.y or 0) / 16)
  return ok and point or nil
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  local records = { self.playerVisual:drawRecord(alpha) }
  for _, record in ipairs(self.actors:drawRecords(alpha)) do records[#records + 1] = record end
  local items = FieldActorDraw.items(records, function(spriteId)
    return self.actorAssets:resident(spriteId)
  end)
  -- A sprite class whose requested clip is absent draws its verified idle pose.
  -- Report it once per actor, never once per frame.
  for _, item in ipairs(items) do
    if item.poseFellBack and not self.posePlaceholders[item.actorId] then
      self.posePlaceholders[item.actorId] = true
      io.stderr:write(string.format("actor.pose_fallback %s sprite %d\n",
        item.actorId, item.spriteId or -1))
    end
  end
  return items
end

function FieldState:_worldDraws(alpha)
  local list = self:_actorDraws(alpha)
  if self.runtimeMap.coverageRuntime then
    for _, draw in ipairs(self.runtimeMap.coverageRuntime.draws) do list[#list + 1] = draw end
  end
  if not self.overlaysVisible then return list end

  -- Developer pins only. The player prism and the object-event boxes mark the
  -- logical anchor of each actor, which the drawn billboards are placed from.
  append(list, {
    mesh = self.playerMesh, material = self.playerMaterial,
    transform = Matrix4.translate(self.actor.worldX, self.actor.worldY, self.actor.worldZ),
    center = { 0, 0.8, 0 },
  })
  for _, record in ipairs(self.actors:drawRecords(0)) do
    append(list, {
      mesh = self.actorMesh, material = self.eventMaterial,
      transform = Matrix4.translate(record.world.x, record.world.y, record.world.z),
      center = { 0, 0.8, 0 },
    })
  end

  local events = self.runtimeMap.fieldData.events
  for _, category in ipairs({ "background", "warps", "coordinates" }) do
    for _, event in ipairs(events[category] or {}) do
      local point = self:_eventPoint(event)
      if point then
        append(list, {
          mesh = self.eventMesh, material = self.eventMaterial,
          transform = Matrix4.translate(point.x, point.y, point.z),
          center = { 0, 0.95, 0 },
        })
      end
    end
  end
  for _, plate in ipairs(self.runtimeMap.terrain.plates) do
    if plate.walkable ~= false then
      local localX, localZ = (plate.minX + plate.maxX) / 2, (plate.minZ + plate.maxZ) / 2
      local worldX, worldZ = FieldGrid.tileCenterToWorld(localX - 0.5, localZ - 0.5)
      local worldY = self.runtimeMap.terrain:sampleHeight(plate.id, localX, localZ)
      append(list, {
        mesh = self.terrainMesh, material = self.terrainMaterial,
        transform = Matrix4.translate(worldX, worldY, worldZ),
        center = { 0, 0.6, 0 },
      })
    end
  end
  return list
end

function FieldState:draw()
  local lg = love.graphics
  if self.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Field runtime failed:", 24, 24)
    lg.printf(self.errorText, 24, 48, lg.getWidth() - 48)
    return
  end
  local width, height = lg.getDimensions()
  if self.viewport.width ~= width or self.viewport.height ~= height then
    self.viewport:resize(width, height)
    self:_updateCameraProjection()
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
  end
  self.renderer:draw(self.runtime, self.camera,
    self:_worldDraws(self.session:renderAlpha()), self.viewport)
  if self.transition and self.transition.fadeAlpha > 0 then
    local rectangle = self.viewport.worldViewport
    lg.setColor(0, 0, 0, self.transition.fadeAlpha)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  self:_drawHud()
end

-- The inspector walks the map's object-event records, not the live actors, so a
-- hidden actor can still be selected and toggled back into existence.
function FieldState:_inspectorLine()
  local objects = self.runtimeMap.fieldData.events.objects or {}
  if #objects == 0 then return "inspector: map has no object events" end
  local event = objects[self.inspectorIndex + 1]
  local actor = self.actors:getById(
    string.format("map:%d:object:%d", self.runtimeMap.mapId, event.objectEventId))
  if not actor then
    return string.format(
      "inspector %d/%d  object %d  sprite %d  field (%d,%d)  flag %d  script %d  HIDDEN",
      self.inspectorIndex + 1, #objects, event.objectEventId, event.spriteId,
      event.x, event.z, event.eventFlag, event.scriptId)
  end
  local info = actor:describe()
  return string.format(
    "inspector %d/%d  object %d  sprite %d (mmodel %s)  field (%d,%d) surface %d  %s"
      .. "  movement %d  flag %d  script %d",
    self.inspectorIndex + 1, #objects, info.objectEventId, info.spriteId,
    tostring(info.mapModelId), info.fieldX, info.fieldZ, info.surfaceId, info.facing,
    info.movement, info.eventFlag, info.scriptId)
end

-- Developer mutation: writes through FieldEventState, never the actor manager,
-- so the runtime path under test is the same one a script will later use.
function FieldState:_toggleInspectorFlag()
  local objects = self.runtimeMap.fieldData.events.objects or {}
  local event = objects[self.inspectorIndex + 1]
  if not event then return end
  if event.eventFlag == 0 then
    self.saveStatus = "developer: object " .. event.objectEventId .. " has no dedicated flag"
    return
  end
  local set = not self.eventState:isFlagSet(event.eventFlag)
  if set then self.eventState:setFlag(event.eventFlag)
  else self.eventState:clearFlag(event.eventFlag) end
  self.saveStatus = string.format("developer: map %d object %d flag %d %s",
    self.runtimeMap.mapId, event.objectEventId, event.eventFlag, set and "set" or "cleared")
end

-- Developer control: cycle the player graphic through the manifest order, so
-- both avatars are verifiable before the save schema carries the choice.
function FieldState:_cycleAvatar()
  local avatars = FieldActorManifest.avatars
  local index = self.avatar.index % #avatars + 1
  local avatar = avatars[index]
  -- Acquire before releasing: cycling back to the same sprite must not let its
  -- last reference drop and dispose the resident visual.
  local asset = self.actorAssets:acquire(avatar.spriteId)
  self.actorAssets:release(self.avatarAsset.spriteId)
  self.avatar = { index = index, id = avatar.id, spriteId = avatar.spriteId }
  self.avatarAsset = asset
  self.playerVisual:setAvatar(avatar.spriteId, asset.visual)
  self.saveStatus = string.format("developer: avatar %s (sprite %d)", avatar.id, avatar.spriteId)
end

function FieldState:_drawHud()
  local lg = love.graphics
  local events = self.runtimeMap.fieldData.events
  local plan = self.runtimeMap.coveragePlan
  local playerStatus = self.player:status()
  local visuals = self.actorAssets:stats()
  local lines = {
    string.format("field  %s", self.versionId),
    string.format("map %d  %s  camera %d/%s", self.runtimeMap.mapId,
      self.runtimeMap.mapSymbol, self.runtimeMap.cameraType, self.camera.projectionType),
    string.format("player field (%d,%d) local (%d,%d) y %.3f surface %d facing %s %s %d/%d",
      self.actor.fieldX, self.actor.fieldZ, self.actor.localX, self.actor.localZ,
      self.actor.worldY, self.actor.surfaceId, self.actor.facing, self.actor.motion,
      self.actor.progressTicks, self.actor.durationTicks),
    string.format("terrain %s normal %.3f/%.3f/%.3f destination %s",
      tostring(playerStatus.slopeClass), playerStatus.surfaceNormal.x,
      playerStatus.surfaceNormal.y, playerStatus.surfaceNormal.z,
      tostring(playerStatus.destinationSurfaceId)),
    string.format("camera y source/applied %.3f/%.3f  zoom %.2f (manual %.2f)",
      self.camera.cameraSourceY, self.camera.cameraAppliedY,
      self.camera.zoom, self.zoom.manualZoom),
    string.format("viewport height %d  reference height %d  resize compensation %.2f",
      self.viewport.worldViewport.height, self.zoom.referenceHeight, self.zoom.resizeCompensation),
    string.format("events bg/object/warp/coord %d/%d/%d/%d",
      #(events.background or {}), #(events.objects or {}),
      #(events.warps or {}), #(events.coordinates or {})),
    string.format("terrain %d plates  coverage %d cells  visible/prefetch misses %d/%d  resident maps %d",
      #self.runtimeMap.terrain.plates, plan and #plan.cells or 0,
      plan and #(plan.missingVisibleCells or {}) or 0,
      plan and #(plan.missingPrefetchCells or {}) or 0, self.mapLoader:residentCount()),
    string.format("actors %d visible of %d  visuals live/refs %d/%d  scenario %s (%d hidden)",
      #self.actors:actorsOf(self.runtimeMap.mapId), #(events.objects or {}),
      visuals.live, visuals.references,
      FieldScenarioManifest.id, #self.scenarioApplied),
    string.format("avatar %s sprite %d  pose %s tick %d  facing %s",
      self.avatar.id, self.avatar.spriteId, self.playerVisual.pose,
      self.playerVisual.poseTick, self.player.facing),
    self:_inspectorLine(),
    string.format("tick %d  dropped %d  overlays %s",
      self.session.tick, self.session.discardedTicks, self.overlaysVisible and "on" or "off"),
    string.format("transition %s  fade %.2f",
      self.transition.phase, self.transition.fadeAlpha),
    self.saveStatus or "save not written this run",
    "WASD/arrows move   -/= zoom   0 reset zoom   F1 overlays   F2 inspect   F3 toggle flag"
      .. "   F4 avatar   F5 save   F9 reset   Esc quit",
  }
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 900, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do lg.print(line, 20, 12 + (index - 1) * 20) end
end

function FieldState:keypressed(key)
  if key == "escape" then love.event.quit(0) end
  if key == "f1" then self.overlaysVisible = not self.overlaysVisible end
  if key == "f2" then
    local count = #(self.runtimeMap.fieldData.events.objects or {})
    if count > 0 then self.inspectorIndex = (self.inspectorIndex + 1) % count end
  end
  if key == "f3" then self:_toggleInspectorFlag() end
  if key == "f4" then self:_cycleAvatar() end
  if key == "f5" then self:_save() end
  if key == "f9" then self:_reset() return end
  if key == "-" or key == "kp-" then
    self.zoom:zoomOut()
    self:_applyZoomChange()
    return
  end
  if key == "=" or key == "+" or key == "kp+" then
    self.zoom:zoomIn()
    self:_applyZoomChange()
    return
  end
  if key == "0" or key == "kp0" then
    self.zoom:reset()
    self:_applyZoomChange()
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction and self.input then
    self.heldDirectionKeys[key] = direction
    self.input:press(direction)
  end
end

function FieldState:keyreleased(key)
  local direction = self.heldDirectionKeys and self.heldDirectionKeys[key]
  if not direction or not self.input then return end
  self.heldDirectionKeys[key] = nil
  for _, heldDirection in pairs(self.heldDirectionKeys) do
    if heldDirection == direction then return end
  end
  self.input:release(direction)
end

function FieldState:_release()
  if self.actors then self.actors:dispose() end
  if self.avatarAsset and self.actorAssets then
    self.actorAssets:release(self.avatarAsset.spriteId)
  end
  self.avatarAsset, self.playerVisual = nil, nil
  if self.actorAssets then self.actorAssets:dispose() end
  if self.renderer then self.renderer:release() end
  if self.mapLoader then self.mapLoader:release() end
  for _, key in ipairs({ "playerMesh", "actorMesh", "eventMesh", "terrainMesh" }) do
    if self[key] then self[key]:release() end
    self[key] = nil
  end
  self.actors, self.actorAssets, self.renderer, self.mapLoader = nil, nil, nil, nil
end

function FieldState:quit()
  self:_save("Field session saved on quit")
  self:_release()
end

return FieldState
