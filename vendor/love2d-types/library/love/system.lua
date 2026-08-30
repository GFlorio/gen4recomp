---@meta

---@class love.system
love.system = {}

---@return string text
function love.system.getClipboardText() end

---@return string osString
function love.system.getOS() end

---@return love.PowerState state
---@return number percent
---@return number seconds
function love.system.getPowerInfo() end

---@return number processorCount
function love.system.getProcessorCount() end

---@return boolean backgroundmusic
function love.system.hasBackgroundMusic() end

---@param url string
---@return boolean success
function love.system.openURL(url) end

---@param text string
function love.system.setClipboardText(text) end

---@param seconds? number
function love.system.vibrate(seconds) end

---@alias love.PowerState
---| "unknown"
---| "battery"
---| "nobattery"
---| "charging"
---| "charged"
