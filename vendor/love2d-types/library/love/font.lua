---@meta

---@class love.font
love.font = {}

---@overload fun(fileName: string, glyphs: string, dpiscale?: number):love.Rasterizer
---@param imageData love.ImageData
---@param glyphs string
---@param dpiscale? number
---@return love.Rasterizer rasterizer
function love.font.newBMFontRasterizer(imageData, glyphs, dpiscale) end

---@param rasterizer love.Rasterizer
---@param glyph number
function love.font.newGlyphData(rasterizer, glyph) end

---@param imageData love.ImageData
---@param glyphs string
---@param extraSpacing? number
---@param dpiscale? number
---@return love.Rasterizer rasterizer
function love.font.newImageRasterizer(imageData, glyphs, extraSpacing, dpiscale) end

---@overload fun(data: love.FileData):love.Rasterizer
---@overload fun(size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Rasterizer
---@overload fun(fileName: string, size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Rasterizer
---@overload fun(fileData: love.FileData, size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Rasterizer
---@overload fun(imageData: love.ImageData, glyphs: string, dpiscale?: number):love.Rasterizer
---@overload fun(fileName: string, glyphs: string, dpiscale?: number):love.Rasterizer
---@param filename string
---@return love.Rasterizer rasterizer
function love.font.newRasterizer(filename) end

---@overload fun(fileName: string, size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Rasterizer
---@overload fun(fileData: love.FileData, size?: number, hinting?: love.HintingMode, dpiscale?: number):love.Rasterizer
---@param size? number
---@param hinting? love.HintingMode
---@param dpiscale? number
---@return love.Rasterizer rasterizer
function love.font.newTrueTypeRasterizer(size, hinting, dpiscale) end

---@class love.GlyphData: love.Data, love.Object
local GlyphData = {}

---@return number advance
function GlyphData:getAdvance() end

---@return number bx
---@return number by
function GlyphData:getBearing() end

---@return number x
---@return number y
---@return number width
---@return number height
function GlyphData:getBoundingBox() end

---@return number width
---@return number height
function GlyphData:getDimensions() end

---@return love.PixelFormat format
function GlyphData:getFormat() end

---@return number glyph
function GlyphData:getGlyph() end

---@return string glyph
function GlyphData:getGlyphString() end

---@return number height
function GlyphData:getHeight() end

---@return number width
function GlyphData:getWidth() end

---@class love.Rasterizer: love.Object
local Rasterizer = {}

---@return number advance
function Rasterizer:getAdvance() end

---@return number height
function Rasterizer:getAscent() end

---@return number height
function Rasterizer:getDescent() end

---@return number count
function Rasterizer:getGlyphCount() end

---@overload fun(self: love.Rasterizer, glyphNumber: number):love.GlyphData
---@param glyph string
---@return love.GlyphData glyphData
function Rasterizer:getGlyphData(glyph) end

---@return number height
function Rasterizer:getHeight() end

---@return number height
function Rasterizer:getLineHeight() end

---@param glyph1 string|number
---@param glyph2 string|number
---@vararg string|number
---@return boolean hasGlyphs
function Rasterizer:hasGlyphs(glyph1, glyph2, ...) end

---@alias love.HintingMode
---| "normal"
---| "light"
---| "mono"
---| "none"
