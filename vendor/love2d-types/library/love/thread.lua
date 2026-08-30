---@meta

---@class love.thread
love.thread = {}

---@param name string
---@return love.Channel channel
function love.thread.getChannel(name) end

---@return love.Channel channel
function love.thread.newChannel() end

---@overload fun(fileData: love.FileData):love.Thread
---@overload fun(codestring: string):love.Thread
---@param filename string
---@return love.Thread thread
function love.thread.newThread(filename) end

---@class love.Channel: love.Object
local Channel = {}

function Channel:clear() end

---@overload fun(self: love.Channel, timeout: number):any
---@return any value
function Channel:demand() end

---@return number count
function Channel:getCount() end

---@param id number
---@return boolean hasread
function Channel:hasRead(id) end

---@return any value
function Channel:peek() end

---@param func function
---@vararg any
---@return any ret1
function Channel:performAtomic(func, ...) end

---@return any value
function Channel:pop() end

---@param value any
---@return number id
function Channel:push(value) end

---@overload fun(self: love.Channel, value: any, timeout: number):boolean
---@param value any
---@return boolean success
function Channel:supply(value) end

---@class love.Thread: love.Object
local Thread = {}

---@return string err
function Thread:getError() end

---@return boolean value
function Thread:isRunning() end

---@overload fun(self: love.Thread, ...)
function Thread:start() end

function Thread:wait() end
