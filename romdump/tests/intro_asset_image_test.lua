local Assert = require("tests.support.Assert")
local IntroAssetImage = require("romdump.src.digest.IntroAssetImage")

local T = {}

local function surface(width, height)
  local bytes = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      bytes[#bytes + 1] = string.char(x + 1, y + 1, x + y + 1, 255)
    end
  end
  return { width = width, height = height, rgba = table.concat(bytes) }
end

function T.crop_wrapped_samples_no_wrap_and_each_axis()
  local Image = require("romdump.src.digest.IntroAssetImage")
  local source = surface(3, 2)
  local function pixel(result, x, y)
    local offset = (y * result.width + x) * 4
    return string.byte(result.rgba, offset + 1), string.byte(result.rgba, offset + 2)
  end
  local plain = Image.cropWrapped(source, { x = 1, y = 0, width = 2, height = 2 }, 0, 0)
  Assert.deepEqual({ pixel(plain, 0, 0) }, { 2, 1 })
  Assert.deepEqual({ pixel(plain, 1, 1) }, { 3, 2 })
  local xWrapped = Image.cropWrapped(source, { x = 2, y = 0, width = 2, height = 1 }, 1, 0)
  Assert.deepEqual({ pixel(xWrapped, 0, 0) }, { 1, 1 })
  Assert.deepEqual({ pixel(xWrapped, 1, 0) }, { 2, 1 })
  local yWrapped = Image.cropWrapped(source, { x = 0, y = 1, width = 1, height = 2 }, 0, 1)
  Assert.deepEqual({ pixel(yWrapped, 0, 0) }, { 1, 1 })
  Assert.deepEqual({ pixel(yWrapped, 0, 1) }, { 1, 2 })
end

function T.crop_wrapped_handles_both_axes_and_rejects_invalid_geometry()
  local Image = require("romdump.src.digest.IntroAssetImage")
  local source = surface(3, 2)
  local result = Image.cropWrapped(source, { x = 2, y = 1, width = 2, height = 2 }, 1, 1)
  Assert.equal(string.byte(result.rgba, 1), 1)
  Assert.equal(string.byte(result.rgba, 2), 1)
  Assert.equal(string.byte(result.rgba, 5), 2)
  Assert.throws(function()
    Image.cropWrapped(source, { x = 0, y = 0, width = 0, height = 1 }, 0, 0)
  end)
end

function T.reduces_rows_by_dominant_color_and_stable_tie_break()
  local rgba = string.char(10, 0, 0, 255, 20, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255, 0, 0, 0, 0, 1, 0, 0, 255)
  local gradient = IntroAssetImage.reduceGradient(3, 2, rgba)
  Assert.equal(gradient.width, 1)
  Assert.equal(gradient.height, 2)
  Assert.equal(gradient.rgba, string.char(20, 0, 0, 255, 1, 0, 0, 255))
end

function T.rejects_transparent_rows_and_flat_gradients()
  local ok, err = pcall(IntroAssetImage.reduceGradient, 1, 2, string.char(1, 2, 3, 255, 0, 0, 0, 0))
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("opaque", 1, true) ~= nil)

  ok, err = pcall(IntroAssetImage.reduceGradient, 1, 2, string.char(1, 2, 3, 255, 1, 2, 3, 255))
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("flat", 1, true) ~= nil)
end

function T.crops_static_and_animated_alpha_union_with_stable_anchor()
  local function pointSurface(points)
    local pixels = {}
    for i = 1, 4 * 3 * 4 do
      pixels[i] = string.char(0)
    end
    for _, point in ipairs(points) do
      local offset = (point.y * 4 + point.x) * 4 + 1
      pixels[offset] = string.char(point.r)
      pixels[offset + 1] = string.char(point.g)
      pixels[offset + 2] = string.char(point.b)
      pixels[offset + 3] = string.char(255)
    end
    return { width = 4, height = 3, rgba = table.concat(pixels) }
  end
  local frames = {
    pointSurface({ { x = 1, y = 1, r = 4, g = 5, b = 6 } }),
    pointSurface({ { x = 2, y = 2, r = 7, g = 8, b = 9 } }),
  }
  local cropped = IntroAssetImage.cropAlphaUnion(frames, { x = 2, y = 2 })
  Assert.equal(cropped.width, 2)
  Assert.equal(cropped.height, 2)
  Assert.deepEqual(cropped.anchor, { x = 1, y = 1 })
  Assert.equal(cropped.frames[1].width, 2)
  Assert.equal(cropped.frames[2].height, 2)
  Assert.deepEqual(cropped.sourceBounds, { x = 1, y = 1, width = 2, height = 2 })

  local ok, err = pcall(IntroAssetImage.cropAlphaUnion, {
    { width = 1, height = 1, rgba = string.char(0, 0, 0, 0) },
  }, { x = 0, y = 0 })
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("visible", 1, true) ~= nil)
end

return { tests = T }
