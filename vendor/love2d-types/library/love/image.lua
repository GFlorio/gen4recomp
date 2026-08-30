---@meta

---@class love.image
love.image = {}

---@overload fun(fileData: love.FileData):boolean
---@param filename string
---@return boolean compressed
function love.image.isCompressed(filename) end

---@overload fun(fileData: love.FileData):love.CompressedImageData
---@param filename string
---@return love.CompressedImageData compressedImageData
function love.image.newCompressedData(filename) end

---@overload fun(width: number, height: number, format?: love.PixelFormat, data?: string):love.ImageData
---@overload fun(width: number, height: number, data: string):love.ImageData
---@overload fun(filename: string):love.ImageData
---@overload fun(filedata: love.FileData):love.ImageData
---@param width number
---@param height number
---@return love.ImageData imageData
function love.image.newImageData(width, height) end

---@class love.CompressedImageData: love.Data, love.Object
local CompressedImageData = {}

---@overload fun(self: love.CompressedImageData, level: number):number, number
---@return number width
---@return number height
function CompressedImageData:getDimensions() end

---@return love.CompressedImageFormat format
function CompressedImageData:getFormat() end

---@overload fun(self: love.CompressedImageData, level: number):number
---@return number height
function CompressedImageData:getHeight() end

---@return number mipmaps
function CompressedImageData:getMipmapCount() end

---@overload fun(self: love.CompressedImageData, level: number):number
---@return number width
function CompressedImageData:getWidth() end

---@class love.ImageData: love.Data, love.Object
local ImageData = {}

---@overload fun(self: love.ImageData, outFile: string)
---@overload fun(self: love.ImageData, outFile: string, format: love.ImageFormat)
---@param format love.ImageFormat
---@param filename? string
---@return love.FileData filedata
function ImageData:encode(format, filename) end

---@return number width
---@return number height
function ImageData:getDimensions() end

---@return number height
function ImageData:getHeight() end

---@param x number
---@param y number
---@return number r
---@return number g
---@return number b
---@return number a
function ImageData:getPixel(x, y) end

---@return number width
function ImageData:getWidth() end

---@param pixelFunction function
---@param x? number
---@param y? number
---@param width? number
---@param height? number
function ImageData:mapPixel(pixelFunction, x, y, width, height) end

---@param source love.ImageData
---@param dx number
---@param dy number
---@param sx number
---@param sy number
---@param sw number
---@param sh number
function ImageData:paste(source, dx, dy, sx, sy, sw, sh) end

---@overload fun(self: love.ImageData, x: number, y: number, color: table)
---@param x number
---@param y number
---@param r number
---@param g number
---@param b number
---@param a number
function ImageData:setPixel(x, y, r, g, b, a) end

---@return love.PixelFormat format
function ImageData:getFormat() end

---@alias love.CompressedImageFormat
---| "DXT1"
---| "DXT3"
---| "DXT5"
---| "BC4"
---| "BC4s"
---| "BC5"
---| "BC5s"
---| "BC6h"
---| "BC6hs"
---| "BC7"
---| "ETC1"
---| "ETC2rgb"
---| "ETC2rgba"
---| "ETC2rgba1"
---| "EACr"
---| "EACrs"
---| "EACrg"
---| "EACrgs"
---| "PVR1rgb2"
---| "PVR1rgb4"
---| "PVR1rgba2"
---| "PVR1rgba4"
---| "ASTC4x4"
---| "ASTC5x4"
---| "ASTC5x5"
---| "ASTC6x5"
---| "ASTC6x6"
---| "ASTC8x5"
---| "ASTC8x6"
---| "ASTC8x8"
---| "ASTC10x5"
---| "ASTC10x6"
---| "ASTC10x8"
---| "ASTC10x10"
---| "ASTC12x10"
---| "ASTC12x12"

---@alias love.ImageFormat
---| "tga"
---| "png"
---| "jpg"
---| "bmp"

---@alias love.PixelFormat
---| "unknown"
---| "normal"
---| "hdr"
---| "r8"
---| "rg8"
---| "rgba8"
---| "srgba8"
---| "r16"
---| "rg16"
---| "rgba16"
---| "r16f"
---| "rg16f"
---| "rgba16f"
---| "r32f"
---| "rg32f"
---| "rgba32f"
---| "la8"
---| "rgba4"
---| "rgb5a1"
---| "rgb565"
---| "rgb10a2"
---| "rg11b10f"
---| "stencil8"
---| "depth16"
---| "depth24"
---| "depth32f"
---| "depth24stencil8"
---| "depth32fstencil8"
---| "DXT1"
---| "DXT3"
---| "DXT5"
---| "BC4"
---| "BC4s"
---| "BC5"
---| "BC5s"
---| "BC6h"
---| "BC6hs"
---| "BC7"
---| "ETC1"
---| "ETC2rgb"
---| "ETC2rgba"
---| "ETC2rgba1"
---| "EACr"
---| "EACrs"
---| "EACrg"
---| "EACrgs"
---| "PVR1rgb2"
---| "PVR1rgb4"
---| "PVR1rgba2"
---| "PVR1rgba4"
---| "ASTC4x4"
---| "ASTC5x4"
---| "ASTC5x5"
---| "ASTC6x5"
---| "ASTC6x6"
---| "ASTC8x5"
---| "ASTC8x6"
---| "ASTC8x8"
---| "ASTC10x5"
---| "ASTC10x6"
---| "ASTC10x8"
---| "ASTC10x10"
---| "ASTC12x10"
---| "ASTC12x12"
