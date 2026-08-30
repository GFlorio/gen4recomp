---@meta

---@class love.filesystem
love.filesystem = {}

---@overload fun(name: string, data: love.Data, size?: number):boolean, string
---@param name string
---@param data string
---@param size? number
---@return boolean success
---@return string errormsg
function love.filesystem.append(name, data, size) end

---@return boolean enable
function love.filesystem.areSymlinksEnabled() end

---@param name string
---@return boolean success
function love.filesystem.createDirectory(name) end

---@return string path
function love.filesystem.getAppdataDirectory() end

---@return string paths
function love.filesystem.getCRequirePath() end

---@overload fun(dir: string, callback: function):table
---@param dir string
---@return string[] files
function love.filesystem.getDirectoryItems(dir) end

---@return string name
function love.filesystem.getIdentity() end

---@overload fun(path: string, info: table):table
---@overload fun(path: string, filtertype: love.FileType, info: table):table
---@param path string
---@param filtertype? love.FileType
---@return {type: love.FileType, size: number, modtime: number} info
function love.filesystem.getInfo(path, filtertype) end

---@param filepath string
---@return string realdir
function love.filesystem.getRealDirectory(filepath) end

---@return string paths
function love.filesystem.getRequirePath() end

---@return string dir
function love.filesystem.getSaveDirectory() end

---@return string path
function love.filesystem.getSource() end

---@return string path
function love.filesystem.getSourceBaseDirectory() end

---@return string path
function love.filesystem.getUserDirectory() end

---@return string cwd
function love.filesystem.getWorkingDirectory() end

---@param appname string
function love.filesystem.init(appname) end

---@return boolean fused
function love.filesystem.isFused() end

---@param name string
---@return function iterator
function love.filesystem.lines(name) end

---@param name string
---@return function chunk
---@return string errormsg
function love.filesystem.load(name) end

---@overload fun(filedata: love.FileData, mountpoint: string, appendToPath?: boolean):boolean
---@overload fun(data: love.Data, archivename: string, mountpoint: string, appendToPath?: boolean):boolean
---@param archive string
---@param mountpoint string
---@param appendToPath? boolean
---@return boolean success
function love.filesystem.mount(archive, mountpoint, appendToPath) end

---@overload fun(filename: string, mode: love.FileMode):love.File, string
---@param filename string
---@return love.File file
function love.filesystem.newFile(filename) end

---@overload fun(originaldata: love.Data, name: string):love.FileData
---@overload fun(filepath: string):love.FileData, string
---@param contents string
---@param name string
---@return love.FileData data
function love.filesystem.newFileData(contents, name) end

---@overload fun(container: love.ContainerType, name: string, size?: number):love.FileData|string, number, nil, string
---@param name string
---@param size? number
---@return string contents
---@return number size
---@return nil contents
---@return string error
function love.filesystem.read(name, size) end

---@param name string
---@return boolean success
function love.filesystem.remove(name) end

---@param paths string
function love.filesystem.setCRequirePath(paths) end

---@overload fun(name: string)
---@param name string
function love.filesystem.setIdentity(name) end

---@param paths string
function love.filesystem.setRequirePath(paths) end

---@param path string
function love.filesystem.setSource(path) end

---@param enable boolean
function love.filesystem.setSymlinksEnabled(enable) end

---@param archive string
---@return boolean success
function love.filesystem.unmount(archive) end

---@overload fun(name: string, data: love.Data, size?: number):boolean, string
---@param name string
---@param data string
---@param size? number
---@return boolean success
---@return string message
function love.filesystem.write(name, data, size) end

---@class love.DroppedFile: love.File, love.Object
local DroppedFile = {}

---@class love.File: love.Object
local File = {}

---@return boolean success
function File:close() end

---@return boolean success
---@return string err
function File:flush() end

---@return love.BufferMode mode
---@return number size
function File:getBuffer() end

---@return string filename
function File:getFilename() end

---@return love.FileMode mode
function File:getMode() end

---@return number size
function File:getSize() end

---@return boolean eof
function File:isEOF() end

---@return boolean open
function File:isOpen() end

---@return function iterator
function File:lines() end

---@param mode love.FileMode
---@return boolean ok
---@return string err
function File:open(mode) end

---@overload fun(self: love.File, container: love.ContainerType, bytes?: number):love.FileData|string, number
---@param bytes? number
---@return string contents
---@return number size
function File:read(bytes) end

---@param pos number
---@return boolean success
function File:seek(pos) end

---@param mode love.BufferMode
---@param size? number
---@return boolean success
---@return string errorstr
function File:setBuffer(mode, size) end

---@return number pos
function File:tell() end

---@overload fun(self: love.File, data: love.Data, size?: number):boolean, string
---@param data string
---@param size? number
---@return boolean success
---@return string err
function File:write(data, size) end

---@class love.FileData: love.Data, love.Object
local FileData = {}

---@return string ext
function FileData:getExtension() end

---@return string name
function FileData:getFilename() end

---@alias love.BufferMode
---| "none"
---| "line"
---| "full"

---@alias love.FileDecoder
---| "file"
---| "base64"

---@alias love.FileMode
---| "r"
---| "w"
---| "a"
---| "c"

---@alias love.FileType
---| "file"
---| "directory"
---| "symlink"
---| "other"
