---@meta

---@class love.joystick
love.joystick = {}

---@param guid string
---@return string mappingstring
function love.joystick.getGamepadMappingString(guid) end

---@return number joystickcount
function love.joystick.getJoystickCount() end

---@return love.Joystick[] joysticks
function love.joystick.getJoysticks() end

---@overload fun(mappings: string)
---@param filename string
function love.joystick.loadGamepadMappings(filename) end

---@overload fun():string
---@param filename string
---@return string mappings
function love.joystick.saveGamepadMappings(filename) end

---@overload fun(guid: string, axis: love.GamepadAxis, inputtype: love.JoystickInputType, inputindex: number, hatdir?: love.JoystickHat):boolean
---@param guid string
---@param button love.GamepadButton
---@param inputtype love.JoystickInputType
---@param inputindex number
---@param hatdir? love.JoystickHat
---@return boolean success
function love.joystick.setGamepadMapping(guid, button, inputtype, inputindex, hatdir) end

---@class love.Joystick: love.Object
local Joystick = {}

---@return number axisDir1
---@return number axisDir2
---@return number axisDirN
function Joystick:getAxes() end

---@param axis number
---@return number direction
function Joystick:getAxis(axis) end

---@return number axes
function Joystick:getAxisCount() end

---@return number buttons
function Joystick:getButtonCount() end

---@return number vendorID
---@return number productID
---@return number productVersion
function Joystick:getDeviceInfo() end

---@return string guid
function Joystick:getGUID() end

---@param axis love.GamepadAxis
---@return number direction
function Joystick:getGamepadAxis(axis) end

---@overload fun(self: love.Joystick, button: love.GamepadButton):love.JoystickInputType, number, love.JoystickHat
---@param axis love.GamepadAxis
---@return love.JoystickInputType inputtype
---@return number inputindex
---@return love.JoystickHat hatdirection
function Joystick:getGamepadMapping(axis) end

---@return string mappingstring
function Joystick:getGamepadMappingString() end

---@param hat number
---@return love.JoystickHat direction
function Joystick:getHat(hat) end

---@return number hats
function Joystick:getHatCount() end

---@return number id
---@return number instanceid
function Joystick:getID() end

---@return string name
function Joystick:getName() end

---@return number left
---@return number right
function Joystick:getVibration() end

---@return boolean connected
function Joystick:isConnected() end

---@param buttonN number
---@return boolean anyDown
function Joystick:isDown(buttonN) end

---@return boolean isgamepad
function Joystick:isGamepad() end

---@param buttonN love.GamepadButton
---@return boolean anyDown
function Joystick:isGamepadDown(buttonN) end

---@return boolean supported
function Joystick:isVibrationSupported() end

---@overload fun(self: love.Joystick):boolean
---@overload fun(self: love.Joystick, left: number, right: number, duration?: number):boolean
---@param left number
---@param right number
---@return boolean success
function Joystick:setVibration(left, right) end

---@alias love.GamepadAxis
---| "leftx"
---| "lefty"
---| "rightx"
---| "righty"
---| "triggerleft"
---| "triggerright"

---@alias love.GamepadButton
---| "a"
---| "b"
---| "x"
---| "y"
---| "back"
---| "guide"
---| "start"
---| "leftstick"
---| "rightstick"
---| "leftshoulder"
---| "rightshoulder"
---| "dpup"
---| "dpdown"
---| "dpleft"
---| "dpright"

---@alias love.JoystickHat
---| "c"
---| "d"
---| "l"
---| "ld"
---| "lu"
---| "r"
---| "rd"
---| "ru"
---| "u"

---@alias love.JoystickInputType
---| "axis"
---| "button"
---| "hat"
