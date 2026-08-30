---@meta

-- version: 11.5
---@class love
love = {}

---@return number major
---@return number minor
---@return number revision
---@return string codename
function love.getVersion() end

---@return boolean enabled
function love.hasDeprecationOutput() end

---@overload fun(major: number, minor: number, revision: number):boolean
---@param version string
---@return boolean compatible
function love.isVersionCompatible(version) end

---@param enable boolean
function love.setDeprecationOutput(enable) end

---@class LoveConfig
---@field identity string
---@field appendidentity boolean
---@field version string
---@field console boolean
---@field accelerometerjoystick boolean
---@field externalstorage boolean
---@field gammacorrect boolean
---@field audio {mic:boolean, mixwithsystem:boolean}
---@field window {title:string, icon:string, width:number, height:number, borderless:boolean, resizable:boolean, minwidth:number, minheight:number, fullscreen:boolean, fullscreentype:"desktop"|"exclusive", vsync:number, msaa:number, depth:number, stencil:number, display:number, highdpi:boolean, usedpiscale:boolean, x:number, y:number}
---@field modules {audio:boolean, data:boolean, event:boolean, font:boolean, graphics:boolean, image:boolean, joystick:boolean, keyboard:boolean, math:boolean, mouse:boolean, physics:boolean, sound:boolean, system:boolean, thread:boolean, timer:boolean, touch:boolean, video:boolean, window:boolean}

---@param t LoveConfig
function love.conf(t) end

---@param path string The full platform-dependent path to the directory. It can be used as an argument to love.filesystem.mount, in order to gain read access to the directory with love.filesystem.
function love.directorydropped(path) end

---@param index number The index of the display that changed orientation.
---@param orientation love.DisplayOrientation The new orientation.
function love.displayrotated(index, orientation) end

function love.draw() end

---@param msg string The error message.
---@return function mainLoop Function which handles one frame, including events and rendering, when called. If this is nil then LÖVE exits immediately.
function love.errorhandler(msg) end

---@param file love.DroppedFile The unopened File object representing the file that was dropped.
function love.filedropped(file) end

---@param focus boolean True if the window gains focus, false if it loses focus.
function love.focus(focus) end

---@param joystick love.Joystick The joystick object.
---@param axis love.GamepadAxis The virtual gamepad axis.
---@param value number The new axis value.
function love.gamepadaxis(joystick, axis, value) end

---@param joystick love.Joystick The joystick object.
---@param button love.GamepadButton The virtual gamepad button.
function love.gamepadpressed(joystick, button) end

---@param joystick love.Joystick The joystick object.
---@param button love.GamepadButton The virtual gamepad button.
function love.gamepadreleased(joystick, button) end

---@param joystick love.Joystick The joystick object.
function love.joystickadded(joystick) end

---@param joystick love.Joystick The joystick object.
---@param axis number The axis number.
---@param value number The new axis value.
function love.joystickaxis(joystick, axis, value) end

---@param joystick love.Joystick The joystick object.
---@param hat number The hat number.
---@param direction love.JoystickHat The new hat direction.
function love.joystickhat(joystick, hat, direction) end

---@param joystick love.Joystick The joystick object.
---@param button number The button number.
function love.joystickpressed(joystick, button) end

---@param joystick love.Joystick The joystick object.
---@param button number The button number.
function love.joystickreleased(joystick, button) end

---@param joystick love.Joystick The joystick object.
function love.joystickremoved(joystick) end

---@param key love.KeyConstant Character of the pressed key.
---@param scancode love.Scancode The scancode representing the pressed key.
---@param isrepeat boolean Whether this keypress event is a repeat. The delay between key repeats depends on the user's system settings.
function love.keypressed(key, scancode, isrepeat) end

---@param key love.KeyConstant Character of the pressed key.
---@param scancode love.Scancode The scancode representing the pressed key.
function love.keyreleased(key, scancode) end

---@param arg table Command-line arguments given to the game.
---@param unfilteredArg table Unfiltered command-line arguments given to the executable. (In LÖVE 11.0, the passed arguments excludes the game name and the fused command-line flag (if exist) when runs from non-fused LÖVE executable. Previous version pass the argument as-is without any filtering.)
function love.load(arg, unfilteredArg) end

function love.lowmemory() end

---@param focus boolean Whether the window has mouse focus or not.
function love.mousefocus(focus) end

---@param x number The mouse position on the x-axis.
---@param y number The mouse position on the y-axis.
---@param dx number The amount moved along the x-axis since the last time love.mousemoved was called.
---@param dy number The amount moved along the y-axis since the last time love.mousemoved was called.
---@param istouch boolean True if the mouse button press originated from a touchscreen touch-press.
function love.mousemoved(x, y, dx, dy, istouch) end

---@param x number Mouse x position, in pixels.
---@param y number Mouse y position, in pixels.
---@param button number The button index that was pressed. 1 is the primary mouse button, 2 is the secondary mouse button, and 3 is the middle button. Further buttons are mouse dependent.
---@param istouch boolean True if the mouse button press originated from a touchscreen touch-press.
---@param presses number The number of presses in a short time frame and small area, used to simulate double, triple clicks.
function love.mousepressed(x, y, button, istouch, presses) end

---@param x number Mouse x position, in pixels.
---@param y number Mouse y position, in pixels.
---@param button number The button index that was pressed. 1 is the primary mouse button, 2 is the secondary mouse button, and 3 is the middle button. Further buttons are mouse dependent.
---@param istouch boolean True if the mouse button press originated from a touchscreen touch-press.
---@param presses number The number of presses in a short time frame and small area, used to simulate double, triple clicks.
function love.mousereleased(x, y, button, istouch, presses) end

---@return boolean abort Abort quitting. If true, do not close the game.
function love.quit() end

---@param w number The new width.
---@param h number The new height.
function love.resize(w, h) end

---@return fun() mainLoop Function which handles one frame, including events and rendering, when called.
function love.run() end

---@param text string The UTF-8 encoded unicode candidate text.
---@param start number The start cursor of the selected candidate text.
---@param length number The length of the selected candidate text. May be 0.
function love.textedited(text, start, length) end

---@param text string The UTF-8 encoded unicode text.
function love.textinput(text) end

---@param thread love.Thread The thread which produced the error.
---@param errorstr string The error message.
function love.threaderror(thread, errorstr) end

---@param id lightuserdata The identifier for the touch press.
---@param x number The x-axis position of the touch inside the window, in pixels.
---@param y number The y-axis position of the touch inside the window, in pixels.
---@param dx number The x-axis movement of the touch inside the window, in pixels.
---@param dy number The y-axis movement of the touch inside the window, in pixels.
---@param pressure number The amount of pressure being applied. Most touch screens aren't pressure sensitive, in which case the pressure will be 1.
function love.touchmoved(id, x, y, dx, dy, pressure) end

---@param id lightuserdata The identifier for the touch press.
---@param x number The x-axis position of the touch inside the window, in pixels.
---@param y number The y-axis position of the touch inside the window, in pixels.
---@param dx number The x-axis movement of the touch inside the window, in pixels.
---@param dy number The y-axis movement of the touch inside the window, in pixels.
---@param pressure number The amount of pressure being applied. Most touch screens aren't pressure sensitive, in which case the pressure will be 1.
function love.touchpressed(id, x, y, dx, dy, pressure) end

---@param id lightuserdata The identifier for the touch press.
---@param x number The x-axis position of the touch inside the window, in pixels.
---@param y number The y-axis position of the touch inside the window, in pixels.
---@param dx number The x-axis movement of the touch inside the window, in pixels.
---@param dy number The y-axis movement of the touch inside the window, in pixels.
---@param pressure number The amount of pressure being applied. Most touch screens aren't pressure sensitive, in which case the pressure will be 1.
function love.touchreleased(id, x, y, dx, dy, pressure) end

---@param dt number Time since the last update in seconds.
function love.update(dt) end

---@param visible boolean True if the window is visible, false if it isn't.
function love.visible(visible) end

---@param x number Amount of horizontal mouse wheel movement. Positive values indicate movement to the right.
---@param y number Amount of vertical mouse wheel movement. Positive values indicate upward movement.
function love.wheelmoved(x, y) end

---@class love.Data: love.Object
local Data = {}

---@return love.Data clone
function Data:clone() end

---@return ffi.cdata* pointer
function Data:getFFIPointer() end

---@return lightuserdata pointer
function Data:getPointer() end

---@return number size
function Data:getSize() end

---@return string data
function Data:getString() end

---@class love.Object
local Object = {}

---@return boolean success
function Object:release() end

---@return string type
function Object:type() end

---@param name string
---@return boolean b
function Object:typeOf(name) end

return love
