---@meta

---@class love.touch
love.touch = {}

---@param id lightuserdata
---@return number x
---@return number y
function love.touch.getPosition(id) end

---@param id lightuserdata
---@return number pressure
function love.touch.getPressure(id) end

---@return lightuserdata[] touches
function love.touch.getTouches() end
