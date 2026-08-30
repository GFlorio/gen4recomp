---@meta

---@class love.window
love.window = {}

function love.window.close() end

---@overload fun(px: number, py: number):number, number
---@param pixelvalue number
---@return number value
function love.window.fromPixels(pixelvalue) end

---@return number scale
function love.window.getDPIScale() end

---@param displayindex? number
---@return number width
---@return number height
function love.window.getDesktopDimensions(displayindex) end

---@return number count
function love.window.getDisplayCount() end

---@param displayindex? number
---@return string name
function love.window.getDisplayName(displayindex) end

---@param displayindex? number
---@return love.DisplayOrientation orientation
function love.window.getDisplayOrientation(displayindex) end

---@return boolean fullscreen
---@return love.FullscreenType fstype
function love.window.getFullscreen() end

---@param displayindex? number
---@return {width: number, height: number} modes
function love.window.getFullscreenModes(displayindex) end

---@return love.ImageData imagedata
function love.window.getIcon() end

---@return number width
---@return number height
---@return {fullscreen: boolean, fullscreentype: love.FullscreenType, vsync: boolean, msaa: number, resizable: boolean, borderless: boolean, centered: boolean, display: number, minwidth: number, minheight: number, highdpi: boolean, refreshrate: number, x: number, y: number, srgb: boolean} flags
function love.window.getMode() end

---@return number x
---@return number y
---@return number displayindex
function love.window.getPosition() end

---@return number x
---@return number y
---@return number w
---@return number h
function love.window.getSafeArea() end

---@return string title
function love.window.getTitle() end

---@return number vsync
function love.window.getVSync() end

---@return boolean focus
function love.window.hasFocus() end

---@return boolean focus
function love.window.hasMouseFocus() end

---@return boolean enabled
function love.window.isDisplaySleepEnabled() end

---@return boolean maximized
function love.window.isMaximized() end

---@return boolean minimized
function love.window.isMinimized() end

---@return boolean open
function love.window.isOpen() end

---@return boolean visible
function love.window.isVisible() end

function love.window.maximize() end

function love.window.minimize() end

---@param continuous? boolean
function love.window.requestAttention(continuous) end

function love.window.restore() end

---@param enable boolean
function love.window.setDisplaySleepEnabled(enable) end

---@overload fun(fullscreen: boolean, fstype: love.FullscreenType):boolean
---@param fullscreen boolean
---@return boolean success
function love.window.setFullscreen(fullscreen) end

---@param imagedata love.ImageData
---@return boolean success
function love.window.setIcon(imagedata) end

---@param width number
---@param height number
---@param flags? {fullscreen: boolean, fullscreentype: love.FullscreenType, vsync: boolean, msaa: number, stencil: boolean, depth: number, resizable: boolean, borderless: boolean, centered: boolean, display: number, minwidth: number, minheight: number, highdpi: boolean, x: number, y: number, usedpiscale: boolean, srgb: boolean}
---@return boolean success
function love.window.setMode(width, height, flags) end

---@param x number
---@param y number
---@param displayindex? number
function love.window.setPosition(x, y, displayindex) end

---@param title string
function love.window.setTitle(title) end

---@param vsync number
function love.window.setVSync(vsync) end

---@overload fun(title: string, message: string, buttonlist: table, type?: love.MessageBoxType, attachtowindow?: boolean):number
---@param title string
---@param message string
---@param type? love.MessageBoxType
---@param attachtowindow? boolean
---@return boolean success
function love.window.showMessageBox(title, message, type, attachtowindow) end

---@overload fun(x: number, y: number):number, number
---@param value number
---@return number pixelvalue
function love.window.toPixels(value) end

---@param width number
---@param height number
---@param settings {fullscreen: boolean, fullscreentype: love.FullscreenType, vsync: boolean, msaa: number, resizable: boolean, borderless: boolean, centered: boolean, display: number, minwidth: number, minheight: number, highdpi: boolean, x: number, y: number}
---@return boolean success
function love.window.updateMode(width, height, settings) end

---@alias love.DisplayOrientation
---| "unknown"
---| "landscape"
---| "landscapeflipped"
---| "portrait"
---| "portraitflipped"

---@alias love.FullscreenType
---| "desktop"
---| "exclusive"
---| "normal"

---@alias love.MessageBoxType
---| "info"
---| "warning"
---| "error"
