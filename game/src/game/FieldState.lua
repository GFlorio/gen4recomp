-- Interactive presentation over the non-rendering field runtime.

local FieldRuntime = require("game.src.game.FieldRuntime")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldMenuController = require("libs.engine.src.FieldMenuController")
local FieldMenuRenderer = require("libs.engine.src.FieldMenuRenderer")
local MapRenderer = require("libs.engine.src.MapRenderer")
local SceneAssembly = require("libs.engine.src.SceneAssembly")

local KEY_DIRECTIONS =
  { w = "north", up = "north", s = "south", down = "south", a = "west", left = "west", d = "east", right = "east" }
local GAMEPAD_DIRECTIONS = { dpup = "north", dpdown = "south", dpleft = "west", dpright = "east" }

---@class FieldStateOptions
---@field resumeSave boolean?
---@field resetSave boolean?
---@field zoomConfig table?
---@field development boolean? product mode (the default) hides the playtest HUD and ignores the F1/F2 developer binds

---@class FieldState
---@field runtime FieldRuntime?
---@field renderer any
---@field dialogueRenderer any
---@field menuRenderer FieldMenuRenderer?
---@field runtimeMap any
---@field playerVisual any
---@field actors any
---@field actorAssets any
---@field presentationActorAssets FieldActorAssetProvider?
---@field errorText string?
---@field viewport any
---@field mapLoader any
---@field camera any
---@field envelope any
---@field session any
---@field transition any
---@field dialogue any
---@field saveStatus string?
---@field actionKeys table<string, boolean>?
---@field cancelKeys table<string, boolean>?
---@field input any
---@field zoom any
---@field player FieldPlayer? forwarded from the runtime
---@field development boolean product mode (default) hides the playtest HUD and ignores the F1/F2 developer binds
local FieldState = {}
FieldState.__index = function(self, key)
  local method = FieldState[key]
  if method then
    return method
  end
  local runtime = rawget(self, "runtime")
  return runtime and runtime[key]
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
  local runtime = FieldRuntime.new(versionId, idOrSymbol, runtimeOptions)
  local self = setmetatable({ runtime = runtime, development = options.development == true }, FieldState)
  if runtime.session then
    local ok, err = pcall(function()
      self.renderer = MapRenderer.new()
      self.dialogueRenderer = FieldDialogueRenderer.new({ cacheFs = runtime.cacheFs })
      self.menuRenderer = FieldMenuRenderer.new()
      self.presentationActorAssets = FieldActorAssetProvider.new(runtime.cacheFs)
    end)
    if not ok then
      self:dispose()
      error(err)
    end
  end
  return self
end

function FieldState:update(dt)
  if self.runtime then
    self.runtime:update(dt)
  end
end

function FieldState:_updateCameraProjection()
  self.runtime:_updateCameraProjection()
end
function FieldState:_applyZoomChange()
  self.runtime:_applyZoomChange()
end

function FieldState:_save()
  return self.runtime:_save()
end

function FieldState:_reset()
  return self.runtime:_reset()
end

-- Every actor the frame draws: the ROM-derived player billboard first, then the
-- object actors the manager considers present. Records stay presentation-neutral;
-- FieldActorDraw turns them into world draw items against the resident visuals.
function FieldState:_actorDraws(alpha)
  local records = { self.playerVisual:drawRecord(alpha) }
  for _, record in ipairs(self.actors:drawRecords()) do
    records[#records + 1] = record
  end
  return FieldActorDraw.items(records, function(spriteId)
    local assets = assert(self.presentationActorAssets, "field presentation assets are unavailable")
    local entry = assets:resident(spriteId)
    return entry or assets:acquire(spriteId)
  end)
end

-- The flattened scene draw list: map geometry, buildings, the neighbour ring,
-- then actors. SceneAssembly owns submission ordering -- it numbers every draw
-- monotonically in this source order, so equal-depth translucent ties break
-- map before building before neighbour before actor, deterministically.
function FieldState:_worldDraws(alpha)
  return SceneAssembly.flatten({
    self.runtime.runtimeMap.sceneRuntime.mapDraws,
    self.runtime.runtimeMap.sceneRuntime.buildingDraws,
    self.runtimeMap.coverageRuntime and self.runtimeMap.coverageRuntime.draws or {},
    self:_actorDraws(alpha),
  })
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
    if self.runtime.menuHost then
      self.runtime.menuHost:resize(width, height)
    end
    self:_updateCameraProjection()
    self.mapLoader:updateCoverage(self.runtimeMap, self.camera, self.envelope)
  end
  local alpha = self.session:renderAlpha()
  self.renderer:draw(self.runtime.runtimeMap.sceneRuntime, self.camera, self:_worldDraws(alpha), self.viewport, alpha)
  if self.transition and self.transition.fadeAlpha > 0 then
    local rectangle = self.viewport.worldViewport
    lg.setColor(0, 0, 0, self.transition.fadeAlpha)
    lg.rectangle("fill", rectangle.x, rectangle.y, rectangle.width, rectangle.height)
  end
  -- The dialogue UI composites after the world and the fade, inside the
  -- centered 4:3 reference frame, and before the developer HUD.
  if self.dialogue and self.dialogue:isModal() then
    self.dialogueRenderer:draw(self.dialogue, self.viewport)
  end
  local menu = self.runtime.menuHost
  local presentation = menu and menu:presentation()
  if presentation then
    local controller = FieldMenuController.new({
      items = presentation.definition.items,
      initialCursor = presentation.selectedIndex,
      cancellable = presentation.definition.cancellable,
      cancelValue = presentation.definition.cancelValue,
    })
    assert(self.menuRenderer, "field menu renderer is unavailable"):draw(controller, presentation.layout)
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
    string.format("map %d  %s", self.runtimeMap.mapId, self.runtimeMap.mapSymbol),
    string.format(
      "player (%d,%d) y %.3f surface %d %s %s",
      self.player.fieldX,
      self.player.fieldZ,
      self.player.worldY,
      self.player.surfaceId,
      self.player.facing,
      self.player.motion
    ),
    self.saveStatus or "save not written this run",
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
---@param scancode string
---@param isrepeat boolean
function FieldState:keypressed(key, scancode, isrepeat)
  if key == "escape" then
    love.event.quit(0)
  end
  if self.development then
    if key == "f1" then
      self:_save()
    end
    if key == "f2" then
      self:_reset()
      return
    end
  end
  if self.actionKeys and self.actionKeys[key] and self.input then
    self.input:pressAction("key:" .. key)
  end
  if self.cancelKeys and self.cancelKeys[key] and self.input then
    self.input:pressCancel("key:" .. key)
  end
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
    self.input:pressDirection(direction, "key:" .. key)
  end
end

---@param key string
---@param scancode string
function FieldState:keyreleased(key, scancode)
  if self.actionKeys and self.actionKeys[key] and self.input then
    self.input:releaseAction("key:" .. key)
    return
  end
  if self.cancelKeys and self.cancelKeys[key] and self.input then
    self.input:releaseCancel("key:" .. key)
    return
  end
  if not KEY_DIRECTIONS[key] or not self.input then
    return
  end
  self.input:releaseDirection("key:" .. key)
end

-- Focus loss clears held and edge state so a blurred window cannot feed a
-- stale Action into the next frame's dialogue or movement.
---@param focused boolean
function FieldState:focus(focused)
  if not focused and self.input then
    self.input:clearAll()
  end
end

-- Gamepad Action is the south face button ("a") and Cancel the east face
-- button ("b"), mapped alongside the keyboard bindings. The physical source
-- identity includes the joystick id so two pads cannot alias one button.
---@param joystick love.Joystick
---@param button string
function FieldState:gamepadpressed(joystick, button)
  if not self.input then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.input:pressAction(source)
  end
  if button == "b" then
    self.input:pressCancel(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.input:pressDirection(direction, source)
  end
end

---@param joystick love.Joystick
---@param button string
function FieldState:gamepadreleased(joystick, button)
  if not self.input then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":" .. button
  if button == "a" then
    self.input:releaseAction(source)
  end
  if button == "b" then
    self.input:releaseCancel(source)
  end
  local direction = GAMEPAD_DIRECTIONS[button]
  if direction then
    self.input:releaseDirection(source)
  end
end

-- FieldInput owns the paired-axis cache and hysteresis so all physical
-- directions enter the same source-aware state machine.
---@param joystick love.Joystick
---@param axis string
---@param value number
function FieldState:gamepadaxis(joystick, axis, value)
  if not self.input or (axis ~= "leftx" and axis ~= "lefty") then
    return
  end
  local source = "gamepad:" .. joystick:getID() .. ":left"
  self.input:setStickAxis(source, axis == "leftx" and "x" or "y", value)
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousepressed(x, y, button)
  if self.input and button == 1 then
    self.input:pointerDown("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param dx number
---@param dy number
---@param istouch boolean
function FieldState:mousemoved(x, y, dx, dy, istouch)
  if self.input and not istouch then
    self.input:pointerMove("mouse:1", x, y)
  end
end

---@param x number
---@param y number
---@param button integer
function FieldState:mousereleased(x, y, button)
  if self.input and button == 1 then
    self.input:pointerUp("mouse:1", x, y)
  end
end

---@param x number
---@param y number
function FieldState:wheelmoved(x, y)
  if self.input then
    self.input:pointerScroll("mouse", x, y)
  end
end

---@param id any
---@param x number
---@param y number
function FieldState:touchpressed(id, x, y)
  if self.input then
    self.input:pointerDown("touch:" .. tostring(id), x, y)
  end
end

---@param id any
---@param x number
---@param y number
function FieldState:touchmoved(id, x, y)
  if self.input then
    self.input:pointerMove("touch:" .. tostring(id), x, y)
  end
end

---@param id any
---@param x number
---@param y number
function FieldState:touchreleased(id, x, y)
  if self.input then
    self.input:pointerUp("touch:" .. tostring(id), x, y)
  end
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
