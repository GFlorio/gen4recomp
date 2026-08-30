---@meta

---@class love.sound
love.sound = {}

---@overload fun(filename: string, buffer?: number):love.Decoder
---@param file love.File
---@param buffer? number
---@return love.Decoder decoder
function love.sound.newDecoder(file, buffer) end

---@overload fun(file: love.File):love.SoundData
---@overload fun(decoder: love.Decoder):love.SoundData
---@overload fun(samples: number, rate?: number, bits?: number, channels?: number):love.SoundData
---@param filename string
---@return love.SoundData soundData
function love.sound.newSoundData(filename) end

---@class love.Decoder: love.Object
local Decoder = {}

---@return love.Decoder decoder
function Decoder:clone() end

---@return love.SoundData soundData
function Decoder:decode() end

---@return number bitDepth
function Decoder:getBitDepth() end

---@return number channels
function Decoder:getChannelCount() end

---@return number duration
function Decoder:getDuration() end

---@return number rate
function Decoder:getSampleRate() end

---@param offset number
function Decoder:seek(offset) end

---@class love.SoundData: love.Data, love.Object
local SoundData = {}

---@return number bitdepth
function SoundData:getBitDepth() end

---@return number channels
function SoundData:getChannelCount() end

---@return number duration
function SoundData:getDuration() end

---@overload fun(self: love.SoundData, i: number, channel: number):number
---@param i number
---@return number sample
function SoundData:getSample(i) end

---@return number count
function SoundData:getSampleCount() end

---@return number rate
function SoundData:getSampleRate() end

---@overload fun(self: love.SoundData, i: number, channel: number, sample: number)
---@param i number
---@param sample number
function SoundData:setSample(i, sample) end
