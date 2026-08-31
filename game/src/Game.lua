-- Owns one running game's state lifecycle and LÖVE-shaped event dispatch.

---@class GameOptions
---@field onExit fun(result: table|nil)

---@class Game
---@field state table|nil
---@field drawableWidth number
---@field drawableHeight number
---@field onExit fun(result: table|nil)
---@field terminal boolean
local Game = {}
Game.__index = Game

---@param options GameOptions
---@return Game
function Game.new(options)
  assert(type(options) == "table" and type(options.onExit) == "function", "Game requires an onExit callback")
  local width, height = love.graphics.getDimensions()
  return setmetatable({
    state = nil,
    drawableWidth = width,
    drawableHeight = height,
    onExit = options.onExit,
    terminal = false,
  }, Game)
end

---@param nextState table|nil
function Game:setState(nextState)
  assert(not self.terminal, "cannot set a state after Game disposal")
  local previous = self.state
  self.state = nextState
  if previous and previous.dispose then
    previous:dispose()
  end
end

function Game:_syncDrawableSize()
  local width, height = love.graphics.getDimensions()
  if width == self.drawableWidth and height == self.drawableHeight then
    return
  end
  self.drawableWidth = width
  self.drawableHeight = height
  if self.state and self.state.resize then
    self.state:resize(width, height)
  end
end

function Game:update(dt)
  self:_syncDrawableSize()
  if self.state and self.state.update then
    self.state:update(dt)
  end
end

function Game:draw()
  self:_syncDrawableSize()
  if self.state and self.state.draw then
    self.state:draw()
  end
end

function Game:resize(width, height)
  self.drawableWidth = width
  self.drawableHeight = height
  if self.state and self.state.resize then
    self.state:resize(width, height)
  end
end

function Game:keypressed(key, scancode, isrepeat)
  if self.state and self.state.keypressed then
    self.state:keypressed(key, scancode, isrepeat)
  end
end

function Game:textinput(text)
  if self.state and self.state.textinput then
    self.state:textinput(text)
  end
end

function Game:keyreleased(key, scancode)
  if self.state and self.state.keyreleased then
    self.state:keyreleased(key, scancode)
  end
end

function Game:gamepadpressed(joystick, button)
  if self.state and self.state.gamepadpressed then
    self.state:gamepadpressed(joystick, button)
  end
end

function Game:gamepadreleased(joystick, button)
  if self.state and self.state.gamepadreleased then
    self.state:gamepadreleased(joystick, button)
  end
end

function Game:gamepadaxis(joystick, axis, value)
  if self.state and self.state.gamepadaxis then
    self.state:gamepadaxis(joystick, axis, value)
  end
end

function Game:mousepressed(x, y, button, istouch, presses)
  self:_syncDrawableSize()
  if self.state and self.state.mousepressed then
    self.state:mousepressed(x, y, button, istouch, presses)
  end
end

function Game:mousemoved(x, y, dx, dy, istouch)
  self:_syncDrawableSize()
  if self.state and self.state.mousemoved then
    self.state:mousemoved(x, y, dx, dy, istouch)
  end
end

function Game:mousereleased(x, y, button, istouch, presses)
  self:_syncDrawableSize()
  if self.state and self.state.mousereleased then
    self.state:mousereleased(x, y, button, istouch, presses)
  end
end

function Game:wheelmoved(x, y)
  if self.state and self.state.wheelmoved then
    self.state:wheelmoved(x, y)
  end
end

function Game:touchpressed(id, x, y, dx, dy, pressure)
  self:_syncDrawableSize()
  if self.state and self.state.touchpressed then
    self.state:touchpressed(id, x, y, dx, dy, pressure)
  end
end

function Game:touchmoved(id, x, y, dx, dy, pressure)
  self:_syncDrawableSize()
  if self.state and self.state.touchmoved then
    self.state:touchmoved(id, x, y, dx, dy, pressure)
  end
end

function Game:touchreleased(id, x, y, dx, dy, pressure)
  self:_syncDrawableSize()
  if self.state and self.state.touchreleased then
    self.state:touchreleased(id, x, y, dx, dy, pressure)
  end
end

function Game:focus(focused)
  if self.state and self.state.focus then
    self.state:focus(focused)
  end
end

---@param result table|nil
function Game:exit(result)
  if self.terminal then
    return
  end
  self.terminal = true
  local state = self.state
  self.state = nil
  if state and state.dispose then
    state:dispose()
  end
  self.onExit(result)
end

function Game:dispose()
  if self.terminal then
    return
  end
  self.terminal = true
  local state = self.state
  self.state = nil
  if state and state.dispose then
    state:dispose()
  end
end

return Game
