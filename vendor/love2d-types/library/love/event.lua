---@meta

---@class love.event
love.event = {}

function love.event.clear() end

---@return function i
function love.event.poll() end

function love.event.pump() end

---@param n love.Event
---@param a? any
---@param b? any
---@param c? any
---@param d? any
---@param e? any
---@param f? any
---@vararg any
function love.event.push(n, a, b, c, d, e, f, ...) end

---@overload fun(restart: string|'restart')
---@param exitstatus? number
function love.event.quit(exitstatus) end

---@return love.Event n
---@return any a
---@return any b
---@return any c
---@return any d
---@return any e
---@return any f
function love.event.wait() end

---@alias love.Event
---| "focus"
---| "joystickpressed"
---| "joystickreleased"
---| "keypressed"
---| "keyreleased"
---| "mousepressed"
---| "mousereleased"
---| "quit"
---| "resize"
---| "visible"
---| "mousefocus"
---| "threaderror"
---| "joystickadded"
---| "joystickremoved"
---| "joystickaxis"
---| "joystickhat"
---| "gamepadpressed"
---| "gamepadreleased"
---| "gamepadaxis"
---| "textinput"
---| "mousemoved"
---| "lowmemory"
---| "textedited"
---| "wheelmoved"
---| "touchpressed"
---| "touchreleased"
---| "touchmoved"
---| "directorydropped"
---| "filedropped"
---| "jp"
---| "jr"
---| "kp"
---| "kr"
---| "mp"
---| "mr"
---| "q"
---| "f"
