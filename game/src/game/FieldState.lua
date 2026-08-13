-- Interactive presentation over the non-rendering field runtime.

local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldMenuRenderer = require("libs.engine.src.FieldMenuRenderer")
local MapRenderer = require("libs.engine.src.MapRenderer")
local SceneAssembly = require("libs.engine.src.SceneAssembly")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local KEY_DIRECTIONS =
  { w = "north", up = "north", s = "south", down = "south", a = "west", left = "west", d = "east", right = "east" }
local GAMEPAD_DIRECTIONS = { dpup = "north", dpdown = "south", dpleft = "west", dpright = "east" }

---@class FieldStateOptions
---@field resumeSave boolean?
---@field resetSave boolean?
---@field zoomConfig table?
---@field development boolean? product mode (the default) hides the playtest HUD and ignores the F1/F2 developer binds
---@field topologyProvider fun(width: number, height: number): ScreenTopology

---@class FieldState
---@field runtime FieldRuntime?
---@field renderer any
---@field dialogueRenderer any
---@field menuRenderer FieldMenuRenderer?
---@field presentationActorAssets FieldActorAssetProvider?
---@field development boolean product mode (default) hides the playtest HUD and ignores the F1/F2 developer binds
---@field topologyProvider fun(width: number, height: number): ScreenTopology
local FieldState = {}
FieldState.__index = FieldState

local function defaultScreenTopology(width, height)
  local os = love.system and love.system.getOS and love.system.getOS() or ""
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    touch = os == "Android" or os == "iOS",
    role = "world",
  })
end

function FieldState.new(versionId, idOrSymbol, options)
  options = options or {}
  local runtimeOptions = {}
  for key, value in pairs(options) do
    if key ~= "development" then
      runtimeOptions[key] = value
    end
  end
  runtimeOptions.presentation = true
  -- Construction is binary: FieldRuntime.new either raised (boot failed) or
  -- returned a fully usable runtime, so presentation resources are acquired
  -- unconditionally. A failure here releases the booted runtime exactly once
  -- through the shared disposal and rethrows.
  local runtime = FieldRuntime.new(versionId, idOrSymbol, runtimeOptions)
  local self = setmetatable({
    runtime = runtime,
    development = options.development == true,
    topologyProvider = options.topologyProvider or defaultScreenTopology,
  }, FieldState)
  local ok, err = pcall(function()
    self.renderer = MapRenderer.new()
    self.dialogueRenderer = FieldDialogueRenderer.new({ cacheFs = runtime.cacheFs })
    self.menuRenderer = FieldMenuRenderer.new()
    local width, height = love.graphics.getDimensions()
    runtime.menuHost:setScreenTopology(self.topologyProvider(width, height))
    runtime.menuHost:setPresentationMetrics(function(text)
      return love.graphics.getFont():getWidth(text)
    end)
    self.presentationActorAssets = FieldActorAssetProvider.new(runtime.cacheFs)
  end)
  if not ok then
    self:dispose()
    error(err)
  end
  return self
end

function FieldState:update(dt)
  if self.runtime then
    self.runtime:update(dt)
  end
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  local records = { self.runtime.playerVisual:drawRecord(alpha) }
  for _, record in ipairs(self.runtime.actors:drawRecords()) do
    records[#records + 1] = record
  end
  return FieldActorDraw.items(records, function(spriteId)
    local assets = assert(self.presentationActorAssets, "field presentation assets are unavailable")
    local entry = assets:resident(spriteId)
    return entry or assets:acquire(spriteId)
  end)
end

-- The flattened scene draw list: map geometry, buildings, the neighbour ring,
-- then actors. SceneAssembly owns submission ordering -- it concatenates every
-- part in this source order, so equal-depth translucent ties break
-- map before building before neighbour before actor, deterministically.
function FieldState:_worldDraws(alpha)
  return SceneAssembly.flatten({
    self.runtime.runtimeMap.sceneRuntime.mapDraws,
    self.runtime.runtimeMap.sceneRuntime.buildingDraws,
    self.runtime.runtimeMap.coverageRuntime and self.runtime.runtimeMap.coverageRuntime.draws or {},
    self:_actorDraws(alpha),
  })
end

function FieldState:draw()
  local lg = love.graphics
  if self.runtime.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Field runtime failed:", 24, 24)
    lg.printf(self.runtime.errorText, 24, 48, lg.getWidth() - 48)
    return
  end
  local width, height = lg.getDimensions()
  if self.runtime.viewport.width ~= width or self.runtime.viewport.height ~= height then
    self.runtime.viewport:resize(width, height)
    if self.runtime.menuHost then
      self.runtime.menuHost:resize(width, height)
      self.runtime.menuHost:setScreenTopology(self.topologyProvider(width, height))
    end
    self.runtime:_updateCameraProjection()
    self.runtime.mapLoader:updateCoverage(self.runtime.runtimeMap, self.runtime.camera, self.runtime.envelope)
  end
  local alpha = self.runtime.session:renderAlpha()
  self.renderer:draw(
    self.runtime.runtimeMap.sceneRuntime,
    self.runtime.camera,
    self:_worldDraws(alpha),
    self.runtime.viewport,
    alpha
  )
  if self.runtime.transition and self.runtime.transition.fadeAlpha > 0 then
    local rectangle = self.runtime.viewport.worldViewport
    lg.setColor(0, 0, 0, self.runtime.transition.fadeAlpha)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  -- The dialogue UI composites after the world and the fade, inside the
  -- centered 4:3 reference frame, and before the developer HUD.
  if self.runtime.dialogue and self.runtime.dialogue:isModal() then
    self.dialogueRenderer:draw(self.runtime.dialogue, self.runtime.viewport)
  end
  local menu = self.runtime.menuHost
  local presentation = menu and menu:presentation()
  if presentation then
    assert(self.menuRenderer, "field menu renderer is unavailable"):draw(presentation)
  end
  if self.development then
    self:_drawHud()
  end
end

-- The playtest HUD: map identity, the player's field state, the save status,
-- and the controls. Everything else stays out of the frame until the real
-- game UI replaces even this.
function FieldState:_drawHud()
  local lg = love.graphics
  local lines = {
    string.format("map %d  %s", self.runtime.runtimeMap.mapId, self.runtime.runtimeMap.mapSymbol),
    string.format(
      "player (%d,%d) y %.3f surface %d %s %s",
      self.runtime.player.fieldX,
      self.runtime.player.fieldZ,
      self.runtime.player.worldY,
      self.runtime.player.surfaceId,
      self.runtime.player.facing,
      self.runtime.player.motion
    ),
    self.runtime.saveStatus or "save not written this run",
    "WASD/arrows move   Z/Space/Enter action   X/Backspace cancel   -/= zoom"
      .. "   0 reset zoom   F1 save   F2 reset   Esc quit",
  }
  lg.setColor(0, 0, 0, 0.55)
  lg.rectangle("fill", 12, 12, 900, 20 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do
    lg.print(line, 20, 12 + (index - 1) * 20)
  end
end

---@param key string
---@param scancode string?
---@param isrepeat boolean?
function FieldState:keypressed(key, scancode, isrepeat)
  if key == "escape" then
    love.event.quit(0)
  end
  if self.development then
    if key == "f1" then
      self.runtime:_save()
    end
    if key == "f2" then
      self.runtime:_reset()
      return
    end
  end
  if self.runtime.actionKeys[key] then
    self.runtime.input:pressAction("key:" .. key)
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:pressCancel("key:" .. key)
  end
  if key == "-" or key == "kp-" then
    self.runtime.zoom:zoomOut()
    self.runtime:_applyZoomChange()
    return
  end
  if key == "=" or key == "+" or key == "kp+" then
    self.runtime.zoom:zoomIn()
    self.runtime:_applyZoomChange()
    return
  end
  if key == "0" or key == "kp0" then
    self.runtime.zoom:reset()
    self.runtime:_applyZoomChange()
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:pressDirection(direction, "key:" .. key)
  end
end

---@param key string
---@param scancode string?
function FieldState:keyreleased(key, scancode)
  if self.runtime.actionKeys[key] then
    self.runtime.input:releaseAction("key:" .. key)
    return
  end
  if self.runtime.cancelKeys[key] then
    self.runtime.input:releaseCancel("key:" .. key)
    return
  end
  local direction = KEY_DIRECTIONS[key]
  if direction then
    self.runtime.input:releaseDirection("key:" .. key)
  end
end

-- Focus loss clears held and edge state so a blurred window cannot feed a
-- stale Action into the next frame's dialogue or movement.
---@param focused boolean
function FieldState:focus(focused)
  if not focused then
    self.runtime.input:clearAll()
  end
end

-- Gamepad Action is the south face button ("a") and Cancel the east face
-- button ("b"), mapped alongside the keyboard bindings. The physical source
-- identity includes the joystick id so two pads cannot alias one button.
---@param joystick love.Joystick
---@param button string
function FieldState:gamepadpressed(joystick, button)
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:pressAction(source)
  end
  if button == "b" then
    self.runtime.input:pressCancel(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:pressDirection(direction, source)
  end
end

---@param joystick love.Joystick
---@param button string
function FieldState:gamepadreleased(joystick, button)
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.runtime.input:releaseAction(source)
  end
  if button == "b" then
    self.runtime.input:releaseCancel(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.runtime.input:releaseDirection(source)
  end
end

-- FieldInput owns the paired-axis cache and hysteresis so all physical
-- directions enter the same source-aware state machine.
---@param joystick love.Joystick
---@param axis string
---@param value number
function FieldState:gamepadaxis(joystick, axis, value)
  if axis ~= "leftx" and axis ~= "lefty" then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":left"
  self.runtime.input:setStickAxis(source, axis == "leftx" and "x" or "y", value)
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousepressed(x, y, button)
  if button == 1 then
    self.runtime.input:pointerDown("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param dx number
---@param dy number
---@param istouch boolean
function FieldState:mousemoved(x, y, dx, dy, istouch)
  if not istouch then
    self.runtime.input:pointerMove("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousereleased(x, y, button)
  if button == 1 then
    self.runtime.input:pointerUp("mouse:1", x, y)
  end
end

---@param x number
---@param y number
function FieldState:wheelmoved(x, y)
  self.runtime.input:pointerScroll("mouse", x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchpressed(id, x, y)
  self.runtime.input:pointerDown("touch:" .. tostring(id), x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchmoved(id, x, y)
  self.runtime.input:pointerMove("touch:" .. tostring(id), x, y)
end

---@param id any
---@param x number
---@param y number
function FieldState:touchreleased(id, x, y)
  self.runtime.input:pointerUp("touch:" .. tostring(id), x, y)
end

function FieldState:dispose()
  if self.dialogueRenderer then
    self.dialogueRenderer:release()
    self.dialogueRenderer = nil
  end
  if self.presentationActorAssets then
    self.presentationActorAssets:dispose()
    self.presentationActorAssets = nil
  end
  if self.renderer then
    self.renderer:release()
    self.renderer = nil
  end
  if self.runtime then
    self.runtime:dispose()
    self.runtime = nil
  end
end

return FieldState
