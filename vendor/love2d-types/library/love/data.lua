---@meta

---@class love.data
love.data = {}

---@overload fun(container: love.ContainerType, format: love.CompressedDataFormat, data: love.Data, level?: number):love.CompressedData|string
---@param container love.ContainerType
---@param format love.CompressedDataFormat
---@param rawstring string
---@param level? number
---@return love.CompressedData|string compressedData
function love.data.compress(container, format, rawstring, level) end

---@overload fun(container: love.ContainerType, format: love.EncodeFormat, sourceData: love.Data):love.ByteData|string
---@param container love.ContainerType
---@param format love.EncodeFormat
---@param sourceString string
---@return love.ByteData|string decoded
function love.data.decode(container, format, sourceString) end

---@overload fun(container: love.ContainerType, format: love.CompressedDataFormat, compressedString: string):love.Data|string
---@overload fun(container: love.ContainerType, format: love.CompressedDataFormat, data: love.Data):love.Data|string
---@param container love.ContainerType
---@param compressedData love.CompressedData
---@return love.Data|string decompressedData
function love.data.decompress(container, compressedData) end

---@overload fun(container: love.ContainerType, format: love.EncodeFormat, sourceData: love.Data, linelength?: number):love.ByteData|string
---@param container love.ContainerType
---@param format love.EncodeFormat
---@param sourceString string
---@param linelength? number
---@return love.ByteData|string encoded
function love.data.encode(container, format, sourceString, linelength) end

---@param format string
---@return number size
function love.data.getPackedSize(format) end

---@overload fun(hashFunction: love.HashFunction, data: love.Data):string
---@param hashFunction love.HashFunction
---@param string string
---@return string rawdigest
function love.data.hash(hashFunction, string) end

---@overload fun(Data: love.Data, offset?: number, size?: number):love.ByteData
---@overload fun(size: number):love.ByteData
---@param datastring string
---@return love.ByteData bytedata
function love.data.newByteData(datastring) end

---@param data love.Data
---@param offset number
---@param size number
---@return love.Data view
function love.data.newDataView(data, offset, size) end

---@param container love.ContainerType
---@param format string
---@param v1 number|boolean|string
---@vararg number|boolean|string
---@return love.Data|string data
function love.data.pack(container, format, v1, ...) end

---@overload fun(format: string, data: love.Data, pos?: number):number|boolean|string, number|boolean|string, number
---@param format string
---@param datastring string
---@param pos? number
---@return number|boolean|string v1
---@return number index
function love.data.unpack(format, datastring, pos) end

---@class love.ByteData: love.Object, love.Data
local ByteData = {}

---@class love.CompressedData: love.Data, love.Object
local CompressedData = {}

---@return love.CompressedDataFormat format
function CompressedData:getFormat() end

---@alias love.CompressedDataFormat
---| "lz4"
---| "zlib"
---| "gzip"
---| "deflate"

---@alias love.ContainerType
---| "data"
---| "string"

---@alias love.EncodeFormat
---| "base64"
---| "hex"

---@alias love.HashFunction
---| "md5"
---| "sha1"
---| "sha224"
---| "sha256"
---| "sha384"
---| "sha512"
