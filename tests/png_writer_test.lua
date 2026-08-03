-- PngWriter: signature/chunk framing, determinism, length validation, and (when
-- love.image is available) a decode round-trip proving the pixels survive.

local Assert = require("tests.support.Assert")
local PngWriter = require("src.import.PngWriter")
local Errors = require("src.import.Errors")

local T = {}

local function px(r, g, b, a) return string.char(r, g, b, a) end

function T.starts_with_signature_and_has_ihdr_idat_iend()
  local png = PngWriter.encode(1, 1, px(10, 20, 30, 255))
  Assert.equal(png:sub(1, 8), string.char(137, 80, 78, 71, 13, 10, 26, 10))
  Assert.equal(png:sub(13, 16), "IHDR")
  Assert.isTrue(png:find("IDAT", 1, true) ~= nil, "has IDAT")
  Assert.equal(png:sub(#png - 7, #png - 4), "IEND") -- type precedes its 4-byte CRC
end

function T.is_deterministic()
  local rgba = px(1, 2, 3, 4) .. px(5, 6, 7, 8)
  Assert.equal(PngWriter.encode(2, 1, rgba), PngWriter.encode(2, 1, rgba))
end

function T.rejects_wrong_length()
  local ok, err = pcall(PngWriter.encode, 2, 2, "short")
  Assert.isTrue(not ok and Errors.is(err) and err.code == "PNG_BAD_RGBA_LENGTH", "raises")
end

function T.decodes_back_to_the_same_pixels()
  if not (love and love.image) then return end -- decode check only under love
  local rgba = px(10, 20, 30, 255) .. px(200, 150, 100, 128)
  local png = PngWriter.encode(2, 1, rgba)
  local data = love.image.newImageData(love.filesystem.newFileData(png, "t.png"))
  Assert.equal(data:getWidth(), 2)
  local r, g, b, a = data:getPixel(0, 0)
  Assert.equal(math.floor(r * 255 + 0.5), 10)
  Assert.equal(math.floor(g * 255 + 0.5), 20)
  Assert.equal(math.floor(a * 255 + 0.5), 255)
  local r2 = data:getPixel(1, 0)
  Assert.equal(math.floor(r2 * 255 + 0.5), 200)
end

return T
