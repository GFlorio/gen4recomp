-- Pure reductions from decoded source RGBA surfaces to semantic intro images.

local IntroAssetImage = {}

local function rgbaAt(rgba, width, x, y)
  local offset = (y * width + x) * 4 + 1
  return string.byte(rgba, offset, offset + 3)
end

local function packed(r, g, b, a)
  return ((r * 256 + g) * 256 + b) * 256 + a
end

local function validateSurface(surface)
  assert(type(surface) == "table" and surface.width > 0 and surface.height > 0)
  assert(type(surface.rgba) == "string")
  assert(#surface.rgba == surface.width * surface.height * 4)
end

function IntroAssetImage.reduceGradient(width, height, rgba)
  assert(width > 0 and height > 0 and type(rgba) == "string")
  assert(#rgba == width * height * 4)
  local rows = {}
  local colors = {}
  for y = 0, height - 1 do
    local counts = {}
    local best, bestCount, bestPacked
    for x = 0, width - 1 do
      local r, g, b, a = rgbaAt(rgba, width, x, y)
      if a ~= 0 then
        local color = string.char(r, g, b, a)
        counts[color] = (counts[color] or 0) + 1
        local value = packed(r, g, b, a)
        if not bestCount or counts[color] > bestCount or (counts[color] == bestCount and value < bestPacked) then
          best, bestCount, bestPacked = color, counts[color], value
        end
      end
    end
    assert(best, "intro gradient row contains no opaque pixels")
    rows[#rows + 1] = best
    colors[best] = true
  end
  local distinct = 0
  for _ in pairs(colors) do
    distinct = distinct + 1
  end
  assert(distinct > 1, "intro background gradient is flat")
  return { width = 1, height = height, rgba = table.concat(rows) }
end

function IntroAssetImage.cropAlphaUnion(frames, anchor)
  assert(type(frames) == "table" and #frames > 0)
  local minX, minY, maxX, maxY
  local width, height = frames[1].width, frames[1].height
  for _, frame in ipairs(frames) do
    validateSurface(frame)
    assert(frame.width == width and frame.height == height, "intro animation frame dimensions differ")
    for y = 0, height - 1 do
      for x = 0, width - 1 do
        if (string.byte(frame.rgba, (y * width + x) * 4 + 4) or 0) ~= 0 then
          minX, minY = math.min(minX or x, x), math.min(minY or y, y)
          maxX, maxY = math.max(maxX or x, x), math.max(maxY or y, y)
        end
      end
    end
  end
  assert(minX, "intro image contains no visible pixels")
  local cropWidth, cropHeight = maxX - minX + 1, maxY - minY + 1
  local cropped = {}
  for _, frame in ipairs(frames) do
    local rows = {}
    for y = minY, maxY do
      local row = {}
      for x = minX, maxX do
        local r, g, b, a = rgbaAt(frame.rgba, width, x, y)
        row[#row + 1] = string.char(r or 0, g or 0, b or 0, a or 0)
      end
      rows[#rows + 1] = table.concat(row)
    end
    cropped[#cropped + 1] = { width = cropWidth, height = cropHeight, rgba = table.concat(rows) }
  end
  local sourceAnchor = anchor or { x = width / 2, y = height }
  local anchorX = math.max(0, math.min(cropWidth, sourceAnchor.x - minX))
  local anchorY = math.max(0, math.min(cropHeight, sourceAnchor.y - minY))
  return {
    width = cropWidth,
    height = cropHeight,
    anchor = { x = anchorX, y = anchorY },
    sourceBounds = { x = minX, y = minY, width = cropWidth, height = cropHeight },
    frames = cropped,
  }
end

return IntroAssetImage
