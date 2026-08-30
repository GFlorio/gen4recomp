---@meta

---@class love.audio
love.audio = {}

---@return string[] effects
function love.audio.getActiveEffects() end

---@return number count
function love.audio.getActiveSourceCount() end

---@return love.DistanceModel model
function love.audio.getDistanceModel() end

---@return number scale
function love.audio.getDopplerScale() end

---@param name string
---@return table settings
function love.audio.getEffect(name) end

---@return number maximum
function love.audio.getMaxSceneEffects() end

---@return number maximum
function love.audio.getMaxSourceEffects() end

---@return number fx
---@return number fy
---@return number fz
---@return number ux
---@return number uy
---@return number uz
function love.audio.getOrientation() end

---@return number x
---@return number y
---@return number z
function love.audio.getPosition() end

---@return love.RecordingDevice[] devices
function love.audio.getRecordingDevices() end

---@return number x
---@return number y
---@return number z
function love.audio.getVelocity() end

---@return number volume
function love.audio.getVolume() end

---@return boolean supported
function love.audio.isEffectsSupported() end

---@param samplerate number
---@param bitdepth number
---@param channels number
---@param buffercount? number
---@return love.Source source
function love.audio.newQueueableSource(samplerate, bitdepth, channels, buffercount) end

---@overload fun(file: love.File, type: love.SourceType):love.Source
---@overload fun(decoder: love.Decoder, type: love.SourceType):love.Source
---@overload fun(data: love.FileData, type: love.SourceType):love.Source
---@overload fun(data: love.SoundData):love.Source
---@param filename string
---@param type love.SourceType
---@return love.Source source
function love.audio.newSource(filename, type) end

---@overload fun(source: love.Source, ...)
---@overload fun(sources: table)
---@return love.Source[] Sources
function love.audio.pause() end

---@overload fun(sources: table)
---@overload fun(source1: love.Source, source2: love.Source, ...)
---@param source love.Source
function love.audio.play(source) end

---@param model love.DistanceModel
function love.audio.setDistanceModel(model) end

---@param scale number
function love.audio.setDopplerScale(scale) end

---@overload fun(name: string, enabled?: boolean):boolean
---@param name string
---@param settings {type: love.EffectType, volume: number}
---@return boolean success
function love.audio.setEffect(name, settings) end

---@param mix boolean
---@return boolean success
function love.audio.setMixWithSystem(mix) end

---@param fx number
---@param fy number
---@param fz number
---@param ux number
---@param uy number
---@param uz number
function love.audio.setOrientation(fx, fy, fz, ux, uy, uz) end

---@param x number
---@param y number
---@param z number
function love.audio.setPosition(x, y, z) end

---@param x number
---@param y number
---@param z number
function love.audio.setVelocity(x, y, z) end

---@param volume number
function love.audio.setVolume(volume) end

---@overload fun(source: love.Source)
---@overload fun(source1: love.Source, source2: love.Source, ...)
---@overload fun(sources: table)
function love.audio.stop() end

---@class love.RecordingDevice: love.Object
local RecordingDevice = {}

---@return number bits
function RecordingDevice:getBitDepth() end

---@return number channels
function RecordingDevice:getChannelCount() end

---@return love.SoundData data
function RecordingDevice:getData() end

---@return string name
function RecordingDevice:getName() end

---@return number samples
function RecordingDevice:getSampleCount() end

---@return number rate
function RecordingDevice:getSampleRate() end

---@return boolean recording
function RecordingDevice:isRecording() end

---@param samplecount number
---@param samplerate? number
---@param bitdepth? number
---@param channels? number
---@return boolean success
function RecordingDevice:start(samplecount, samplerate, bitdepth, channels) end

---@return love.SoundData data
function RecordingDevice:stop() end

---@class love.Source: love.Object
local Source = {}

---@return love.Source source
function Source:clone() end

---@return string[] effects
function Source:getActiveEffects() end

---@return number amount
function Source:getAirAbsorption() end

---@return number ref
---@return number max
function Source:getAttenuationDistances() end

---@return number channels
function Source:getChannelCount() end

---@return number innerAngle
---@return number outerAngle
---@return number outerVolume
function Source:getCone() end

---@return number x
---@return number y
---@return number z
function Source:getDirection() end

---@param unit? love.TimeUnit
---@return number duration
function Source:getDuration(unit) end

---@param name string
---@param filtersettings table
---@return {volume: number, highgain: number, lowgain: number} filtersettings
function Source:getEffect(name, filtersettings) end

---@return {type: love.FilterType, volume: number, highgain: number, lowgain: number} settings
function Source:getFilter() end

---@return number buffers
function Source:getFreeBufferCount() end

---@return number pitch
function Source:getPitch() end

---@return number x
---@return number y
---@return number z
function Source:getPosition() end

---@return number rolloff
function Source:getRolloff() end

---@return love.SourceType sourcetype
function Source:getType() end

---@return number x
---@return number y
---@return number z
function Source:getVelocity() end

---@return number volume
function Source:getVolume() end

---@return number min
---@return number max
function Source:getVolumeLimits() end

---@return boolean loop
function Source:isLooping() end

---@return boolean playing
function Source:isPlaying() end

---@return boolean relative
function Source:isRelative() end

function Source:pause() end

---@return boolean success
function Source:play() end

---@param sounddata love.SoundData
---@return boolean success
function Source:queue(sounddata) end

---@param offset number
---@param unit? love.TimeUnit
function Source:seek(offset, unit) end

---@param amount number
function Source:setAirAbsorption(amount) end

---@param ref number
---@param max number
function Source:setAttenuationDistances(ref, max) end

---@param innerAngle number
---@param outerAngle number
---@param outerVolume? number
function Source:setCone(innerAngle, outerAngle, outerVolume) end

---@param x number
---@param y number
---@param z number
function Source:setDirection(x, y, z) end

---@overload fun(self: love.Source, name: string, filtersettings: table):boolean
---@param name string
---@param enable? boolean
---@return boolean success
function Source:setEffect(name, enable) end

---@overload fun(self: love.Source)
---@param settings {type: love.FilterType, volume: number, highgain: number, lowgain: number}
---@return boolean success
function Source:setFilter(settings) end

---@param loop boolean
function Source:setLooping(loop) end

---@param pitch number
function Source:setPitch(pitch) end

---@param x number
---@param y number
---@param z number
function Source:setPosition(x, y, z) end

---@param enable? boolean
function Source:setRelative(enable) end

---@param rolloff number
function Source:setRolloff(rolloff) end

---@param x number
---@param y number
---@param z number
function Source:setVelocity(x, y, z) end

---@param volume number
function Source:setVolume(volume) end

---@param min number
---@param max number
function Source:setVolumeLimits(min, max) end

function Source:stop() end

---@param unit? love.TimeUnit
---@return number position
function Source:tell(unit) end

---@alias love.DistanceModel
---| "none"
---| "inverse"
---| "inverseclamped"
---| "linear"
---| "linearclamped"
---| "exponent"
---| "exponentclamped"

---@alias love.EffectType
---| "chorus"
---| "compressor"
---| "distortion"
---| "echo"
---| "equalizer"
---| "flanger"
---| "reverb"
---| "ringmodulator"

---@alias love.EffectWaveform
---| "sawtooth"
---| "sine"
---| "square"
---| "triangle"

---@alias love.FilterType
---| "lowpass"
---| "highpass"
---| "bandpass"

---@alias love.SourceType
---| "static"
---| "stream"
---| "queue"

---@alias love.TimeUnit
---| "seconds"
---| "samples"
