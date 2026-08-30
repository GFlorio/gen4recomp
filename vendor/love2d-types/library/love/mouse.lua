---@meta

---@class love.mouse
love.mouse = {}

---@return love.Cursor cursor
function love.mouse.getCursor() end

---@return number x
---@return number y
function love.mouse.getPosition() end

---@return boolean enabled
function love.mouse.getRelativeMode() end

---@param ctype love.CursorType
---@return love.Cursor cursor
function love.mouse.getSystemCursor(ctype) end

---@return number x
function love.mouse.getX() end

---@return number y
function love.mouse.getY() end

---@return boolean supported
function love.mouse.isCursorSupported() end

---@param button number
---@vararg number
---@return boolean down
function love.mouse.isDown(button, ...) end

---@return boolean grabbed
function love.mouse.isGrabbed() end

---@return boolean visible
function love.mouse.isVisible() end

---@overload fun(filename: string, hotx?: number, hoty?: number):love.Cursor
---@overload fun(fileData: love.FileData, hotx?: number, hoty?: number):love.Cursor
---@param imageData love.ImageData
---@param hotx? number
---@param hoty? number
---@return love.Cursor cursor
function love.mouse.newCursor(imageData, hotx, hoty) end

---@overload fun()
---@param cursor love.Cursor
function love.mouse.setCursor(cursor) end

---@param grab boolean
function love.mouse.setGrabbed(grab) end

---@param x number
---@param y number
function love.mouse.setPosition(x, y) end

---@param enable boolean
function love.mouse.setRelativeMode(enable) end

---@param visible boolean
function love.mouse.setVisible(visible) end

---@param x number
function love.mouse.setX(x) end

---@param y number
function love.mouse.setY(y) end

---@class love.Cursor: love.Object
local Cursor = {}

---@return love.CursorType ctype
function Cursor:getType() end

---@alias love.CursorType
---| "image"
---| "arrow"
---| "ibeam"
---| "wait"
---| "waitarrow"
---| "crosshair"
---| "sizenwse"
---| "sizenesw"
---| "sizewe"
---| "sizens"
---| "sizeall"
---| "no"
---| "hand"
