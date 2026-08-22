-- Top-level Oak/profile presentation state. It maps host callbacks to one
-- semantic controller, owns text-input mode and intro images, and hands one
-- finalized unpublished candidate to its caller.

local OakIntroLayout = require("game.src.game.OakIntroLayout")
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class OakIntroStateController
---@field start fun(self: OakIntroStateController): boolean
---@field tick fun(self: OakIntroStateController, frames: integer)
---@field view fun(self: OakIntroStateController): OakIntroStateView
---@field result fun(self: OakIntroStateController): table?
---@field press fun(self: OakIntroStateController, action: string): boolean
---@field deleteGlyph fun(self: OakIntroStateController): boolean
---@field inputText fun(self: OakIntroStateController, text: string): boolean
---@field dispose fun(self: OakIntroStateController)

---@class OakIntroStateRenderer
---@field draw fun(self: OakIntroStateRenderer, view: OakIntroStateView)
---@field dispose fun(self: OakIntroStateRenderer)

---@class OakIntroStateTextInputHost
---@field setTextInput fun(self: OakIntroStateTextInputHost, enabled: boolean)

---@class OakIntroStateAudioSink
---@field update? fun(self: OakIntroStateAudioSink)

---@class OakIntroStateRectangle
---@field x number
---@field y number
---@field width number
---@field height number

---@class OakIntroStateLayout
---@field viewport OakIntroStateRectangle
---@field message OakIntroStateRectangle
---@field cards table<integer, OakIntroStateRectangle>
---@field nameGrid table<integer, { rect: OakIntroStateRectangle, kind: string, glyph: string? }>
---@field virtualKeyColumns integer
---@field genderFocus integer

---@class OakIntroStateView
---@field phase string
---@field message string|table|nil
---@field visual string
---@field genderFocus integer
---@field name string
---@field nameInputEnabled boolean
---@field layout OakIntroStateLayout?

---@class OakIntroStateLayoutView: OakIntroStateView
---@field layout OakIntroStateLayout

---@class OakIntroStateOptions
---@field controller OakIntroStateController
---@field manifest table
---@field renderer OakIntroStateRenderer?
---@field imageLoader (fun(path: string): any)?
---@field textInputHost OakIntroStateTextInputHost?
---@field glyphs string[]?
---@field width number?
---@field height number?
---@field onComplete fun(result: table)?
---@field audioSink OakIntroStateAudioSink?

---@class OakIntroState
---@field new fun(options: OakIntroStateOptions): OakIntroState
---@field controller OakIntroStateController
---@field renderer OakIntroStateRenderer
---@field inputHost OakIntroStateTextInputHost
---@field glyphs string[]
---@field width number
---@field height number
---@field accumulator number
---@field textInputEnabled boolean?
---@field completed boolean
---@field onComplete fun(result: table)?
---@field audioSink OakIntroStateAudioSink?
---@field _setTextInput fun(self: OakIntroState, enabled: boolean)
---@field _sync fun(self: OakIntroState): OakIntroStateView
---@field update fun(self: OakIntroState, dt: number)
---@field tick fun(self: OakIntroState, frames: integer)
---@field view fun(self: OakIntroState): OakIntroStateLayoutView
---@field draw fun(self: OakIntroState)
---@field resize fun(self: OakIntroState, width: number, height: number)
---@field keypressed fun(self: OakIntroState, key: string)
---@field textinput fun(self: OakIntroState, text: string)
---@field gamepadpressed fun(self: OakIntroState, joystick: any, button: string)
---@field _pointer fun(self: OakIntroState, x: number, y: number)
---@field mousepressed fun(self: OakIntroState, x: number, y: number, button: integer)
---@field touchpressed fun(self: OakIntroState, id: any, x: number, y: number)
---@field dispose fun(self: OakIntroState)
local OakIntroState = {}
OakIntroState.__index = OakIntroState

local DEFAULT_GLYPHS = {
  "A",
  "B",
  "C",
  "D",
  "E",
  "F",
  "G",
  "H",
  "I",
  "J",
  "K",
  "L",
  "M",
  "N",
  "O",
  "P",
  "Q",
  "R",
  "S",
  "T",
  "U",
  "V",
  "W",
  "X",
  "Y",
  "Z",
}

local function glyphList(value)
  local result = {}
  for _, glyph in ipairs(value or DEFAULT_GLYPHS) do
    assert(type(glyph) == "string", "Oak virtual keyboard glyphs must be strings")
    local count = 0
    for _ in Utf8Glyphs.iter(glyph) do
      count = count + 1
    end
    assert(count == 1, "Oak virtual keyboard entries must be one UTF-8 glyph")
    result[#result + 1] = glyph
  end
  return result
end

local function textInputHost(host)
  if host ~= nil then
    assert(type(host.setTextInput) == "function", "Oak text-input host must provide setTextInput")
    return host
  end
  return {
    setTextInput = function(_, enabled)
      love.keyboard.setTextInput(enabled)
    end,
  }
end

---@param options OakIntroStateOptions
---@return OakIntroState
function OakIntroState.new(options)
  assert(type(options) == "table" and options.controller, "Oak state requires a controller")
  assert(type(options.manifest) == "table", "Oak state requires generated intro assets")
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  local self
  local ok, result = pcall(function()
    local renderer = options.renderer
      or OakIntroRenderer.new({
        manifest = options.manifest,
        imageLoader = options.imageLoader,
      })
    self = setmetatable({
      controller = options.controller,
      renderer = renderer,
      inputHost = textInputHost(options.textInputHost),
      glyphs = glyphList(options.glyphs),
      width = width,
      height = height,
      accumulator = 0,
      textInputEnabled = nil,
      completed = false,
      onComplete = options.onComplete,
      audioSink = options.audioSink,
    }, OakIntroState)
    self:_setTextInput(false)
    self.controller:start()
    return self
  end)
  if not ok then
    if self and self.renderer and self.renderer.dispose then
      pcall(self.renderer.dispose, self.renderer)
    end
    error(result, 0)
  end
  return self
end

function OakIntroState:_setTextInput(enabled)
  if self.textInputEnabled == enabled then
    return
  end
  self.inputHost:setTextInput(enabled)
  self.textInputEnabled = enabled
end

function OakIntroState:_sync()
  local view = self.controller:view()
  self:_setTextInput(view.nameInputEnabled)
  if view.phase == "complete" and not self.completed then
    self.completed = true
    if self.onComplete then
      self.onComplete(assert(self.controller:result()))
    end
  end
  return view
end

function OakIntroState:update(dt)
  assert(type(dt) == "number" and dt >= 0, "Oak update dt must be non-negative")
  self.accumulator = self.accumulator + dt
  while self.accumulator >= 1 / 60 do
    self.accumulator = self.accumulator - 1 / 60
    self.controller:tick(1)
    if self.controller:view().phase == "complete" then
      break
    end
  end
  if self.audioSink and self.audioSink.update then
    self.audioSink:update()
  end
  self:_sync()
end

function OakIntroState:tick(frames)
  self.controller:tick(frames)
  self:_sync()
end

function OakIntroState:view()
  local view = self.controller:view()
  view.layout = OakIntroLayout.compute(self.width, self.height, view, self.glyphs)
  ---@cast view OakIntroStateLayoutView
  return view
end

function OakIntroState:draw()
  self.renderer:draw(self:view())
end

function OakIntroState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number", "Oak resize needs dimensions")
  self.width, self.height = width, height
end

function OakIntroState:keypressed(key)
  if
    key == "left"
    or key == "right"
    or key == "up"
    or key == "down"
    or key == "return"
    or key == "kpenter"
    or key == "space"
    or key == "escape"
  then
    local action = key == "escape" and "cancel"
      or ({ ["left"] = "left", ["right"] = "right", ["up"] = "up", ["down"] = "down" })[key]
      or "confirm"
    if action == "confirm" and self.controller:view().phase == "name_edit" then
      action = "submit"
    end
    self.controller:press(action)
  elseif key == "backspace" then
    self.controller:deleteGlyph()
  end
  self:_sync()
end

function OakIntroState:textinput(text)
  self.controller:inputText(text)
  self:_sync()
end

function OakIntroState:gamepadpressed(_, button)
  local action = ({ dpup = "up", dpdown = "down", dpleft = "left", dpright = "right", a = "confirm", b = "cancel" })[button]
  if
    action == "left"
    or action == "right"
    or action == "up"
    or action == "down"
    or action == "confirm"
    or action == "cancel"
  then
    self.controller:press(action)
  end
  self:_sync()
end

function OakIntroState:_pointer(x, y)
  local view = self:view()
  local layout = view.layout
  if view.phase == "gender_select" then
    for gender = 0, 1 do
      if OakIntroLayout.contains(layout.cards[gender], x, y) then
        self.controller:press(gender == 0 and "left" or "right")
        self.controller:press("confirm")
        return
      end
    end
  elseif view.phase == "name_edit" then
    for _, entry in pairs(layout.nameGrid) do
      if OakIntroLayout.contains(entry.rect, x, y) then
        if entry.kind == "glyph" then
          self.controller:inputText(assert(entry.glyph))
        elseif entry.kind == "delete" then
          self.controller:deleteGlyph()
        elseif entry.kind == "confirm" then
          self.controller:press("submit")
        end
        return
      end
    end
  end
  self:_sync()
end

function OakIntroState:mousepressed(x, y, button)
  if button == 1 then
    self:_pointer(x, y)
  end
end

function OakIntroState:touchpressed(_, x, y)
  self:_pointer(x, y)
end

function OakIntroState:dispose()
  self:_setTextInput(false)
  self.controller:dispose()
  if self.renderer then
    self.renderer:dispose()
    self.renderer = nil
  end
end

return OakIntroState
