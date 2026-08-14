-- Test-side RGBA reader for PngWriter output: PngWriter emits a
-- stored-DEFLATE, filter-0, 8-bit RGBA PNG, so raw pixels are recovered
-- without an inflate implementation. Only that exact shape is supported.

local Assert = require("tests.support.Assert")

local PngReader = {}

-- Returns width, height, and the raw RGBA rows (4 bytes per pixel).
function PngReader.rgba(png)
  Assert.equal(png:sub(1, 8), string.char(137, 80, 78, 71, 13, 10, 26, 10))
  local width = string.byte(png, 17) * 16777216
    + string.byte(png, 18) * 65536
    + string.byte(png, 19) * 256
    + string.byte(png, 20)
  local height = string.byte(png, 21) * 16777216
    + string.byte(png, 22) * 65536
    + string.byte(png, 23) * 256
    + string.byte(png, 24)
  -- The IDAT payload is the first chunk after IHDR.
  local idatLen = string.byte(png, 34) * 16777216
    + string.byte(png, 35) * 65536
    + string.byte(png, 36) * 256
    + string.byte(png, 37)
  local payload = png:sub(42, 41 + idatLen)
  -- Skip the zlib header (2 bytes), then consume stored DEFLATE blocks.
  local pos = 3
  local raw = {}
  repeat
    local final = string.byte(payload, pos)
    local len = string.byte(payload, pos + 1) + string.byte(payload, pos + 2) * 256
    raw[#raw + 1] = payload:sub(pos + 5, pos + 4 + len)
    pos = pos + 5 + len
  until final % 2 == 1
  local rows = table.concat(raw)
  Assert.equal(#rows, height * (width * 4 + 1))
  local rgba = {}
  for y = 0, height - 1 do
    local row = rows:sub(y * (width * 4 + 1) + 2, (y + 1) * (width * 4 + 1))
    Assert.equal(string.byte(rows, y * (width * 4 + 1) + 1), 0, "filter must be 0")
    rgba[#rgba + 1] = row
  end
  return width, height, table.concat(rgba)
end

-- One pixel as r, g, b, a from an rgba buffer returned by PngReader.rgba.
function PngReader.pixel(rgba, width, x, y)
  local offset = (y * width + x) * 4 + 1
  return string.byte(rgba, offset),
    string.byte(rgba, offset + 1),
    string.byte(rgba, offset + 2),
    string.byte(rgba, offset + 3)
end

return PngReader
