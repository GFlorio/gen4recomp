---@meta

---@class love.video
love.video = {}

---@overload fun(file: love.File):love.VideoStream
---@param filename string
---@return love.VideoStream videostream
function love.video.newVideoStream(filename) end

---@class love.VideoStream: love.Object
local VideoStream = {}

---@return string filename
function VideoStream:getFilename() end

---@return boolean playing
function VideoStream:isPlaying() end

function VideoStream:pause() end

function VideoStream:play() end

function VideoStream:rewind() end

---@param offset number
function VideoStream:seek(offset) end

---@return number seconds
function VideoStream:tell() end
