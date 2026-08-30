-- Compiles the small HGSS 2D resource set used by the Professor Oak/profile
-- flow. Nitro container decoding stays in G2dDecoder; this module owns only
-- the source mapping, native-pixel composition, semantic manifest, and
-- producer dependency record.

local Errors = require("libs.errors.src.Errors")
local G2dDecoder = require("romdump.src.digest.G2dDecoder")
local Hashing = require("romdump.src.digest.Hashing")
local Lz10 = require("romdump.src.digest.Lz10")
local PngWriter = require("libs.assets.src.PngWriter")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local IntroAssetImage = require("romdump.src.digest.IntroAssetImage")
local IntroObjPaletteResolver = require("romdump.src.digest.IntroObjPaletteResolver")
local config = require("romdump.src.config.IntroAssets")

local IntroAssetCompiler = {}

local function byteAt(bytes, offset)
  return string.byte(bytes, offset --[[@as integer]])
end

IntroAssetCompiler.ERROR = { SOURCE_INVALID = "INTRO_SOURCE_INVALID" }
-- The source shrink task spends eight calls decrementing its post-change delay,
-- so each replacement remains visible for nine source ticks.
local SHRINK_FRAME_DURATION = 9

local function sourceError(message, context)
  Errors.raise(IntroAssetCompiler.ERROR.SOURCE_INVALID, message, context or {})
end

local function decodeMember(archive, memberId, label, archiveName)
  archiveName = archiveName or config.archive
  local bytes, err = archive:readMember(memberId)
  if not bytes then
    sourceError("source intro member " .. memberId .. " is unavailable: " .. tostring(err), {
      archive = archiveName,
      memberId = memberId,
      label = label,
      sourceOffset = 0,
    })
  end
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      sourceError("source intro member " .. memberId .. " has invalid compression: " .. tostring(lzErr), {
        archive = archiveName,
        memberId = memberId,
        label = label,
        sourceOffset = 0,
      })
    end
    bytes = plain
  end
  return bytes
end

local function decode(kind, bytes, label, memberId, archiveName)
  local value, err = G2dDecoder[kind](bytes, { label = label })
  if not value then
    assert(err)
    sourceError("source intro member " .. memberId .. " failed " .. kind .. ": " .. err.message, {
      archive = archiveName or config.archive,
      memberId = memberId,
      label = label,
      sourceOffset = err.context and err.context.offset or 0,
      cause = err.code,
    })
  end
  return value
end

local function newRgba(width, height)
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  return rgba
end

local function concatBytes(bytes)
  local out = {}
  for i = 1, #bytes, 4096 do
    out[#out + 1] = string.char(unpack(bytes, i, math.min(i + 4095, #bytes)))
  end
  return table.concat(out)
end

local function blitTile(rgba, width, char, x, y, tileIndex, palette, paletteBank, flipH, flipV)
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  if tileIndex < 0 or tileIndex >= tileCount then
    sourceError("intro tile reference exceeds source char data", {
      tile = tileIndex,
      available = tileCount,
      sourceOffset = tileIndex * tileBytes,
    })
  end
  local function put(px, py, value)
    if value == 0 then
      return
    end
    local paletteIndex = value + 1
    if char.depth == 3 then
      paletteIndex = paletteIndex + (paletteBank or 0) * 16
    end
    local color = palette[paletteIndex]
    if not color then
      sourceError("intro pixel references a missing palette entry", { value = value })
    end
    local targetX = flipH and 7 - px or px
    local targetY = flipV and 7 - py or py
    local offset = ((y + targetY) * width + x + targetX) * 4
    rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], rgba[offset + 4] = color.r, color.g, color.b, 255
  end
  local base = tileIndex * tileBytes
  if char.depth == 3 then
    for row = 0, 7 do
      for column = 0, 3 do
        local value = string.byte(char.tiles, base + row * 4 + column + 1)
        put(column * 2, row, value % 16)
        put(column * 2 + 1, row, math.floor(value / 16))
      end
    end
  else
    for row = 0, 7 do
      for column = 0, 7 do
        put(column, row, string.byte(char.tiles, base + row * 8 + column + 1))
      end
    end
  end
end

local function renderChar(char, palette)
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  local width = 16 * 8
  local height = math.ceil(tileCount / 16) * 8
  local rgba = newRgba(width, height)
  for tile = 0, tileCount - 1 do
    blitTile(rgba, width, char, tile % 16 * 8, math.floor(tile / 16) * 8, tile, palette)
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function renderScreen(char, palette, screen)
  local rgba = newRgba(screen.width, screen.height)
  local columns = screen.width / 8
  for row = 0, screen.height / 8 - 1 do
    for column = 0, columns - 1 do
      local entry = screen.entries[row * columns + column + 1]
      blitTile(
        rgba,
        screen.width,
        char,
        column * 8,
        row * 8,
        entry.tile,
        palette,
        entry.palette,
        entry.flipH,
        entry.flipV
      )
    end
  end
  return { width = screen.width, height = screen.height, rgba = concatBytes(rgba) }
end

local function cellBounds(cell, bounds)
  for _, object in ipairs(cell.objs) do
    bounds.minX = math.min(bounds.minX, object.x)
    bounds.minY = math.min(bounds.minY, object.y)
    bounds.maxX = math.max(bounds.maxX, object.x + object.width)
    bounds.maxY = math.max(bounds.maxY, object.y + object.height)
  end
end

-- `colors` here is the sprite's full decoded palette resource (not yet
-- sliced). HGSS's Sprite_SetPaletteOverride renderer path replaces every OAM
-- object's decoded palette-bank field with the sprite template's `.pal`
-- selector when a template override is configured for this resource, so the
-- override (when present) is the effective 4bpp bank for every object in the
-- cell; only when no override is configured does each object's own decoded
-- OAM palette field remain the effective selector.
local function renderCell(char, colors, cell, bounds, paletteOverride)
  if #cell.objs == 0 then
    sourceError("intro cell has no objects", { sourceOffset = 0 })
  end
  local minX, minY = bounds.minX, bounds.minY
  local width, height = bounds.maxX - minX, bounds.maxY - minY
  local rgba = newRgba(width, height)
  for _, object in ipairs(cell.objs) do
    local objectSlot
    if char.depth == 4 then
      objectSlot = nil
    elseif paletteOverride ~= nil then
      objectSlot = paletteOverride
    else
      objectSlot = object.palette
    end
    local ok, objectPalette = pcall(IntroObjPaletteResolver.resolve, colors, char.depth, objectSlot)
    if not ok then
      local err = objectPalette
      if Errors.is(err) then
        ---@cast err Errors.Error
        sourceError(err.message, err.context)
      end
      error(err, 0)
    end
    local columns, rows = object.width / 8, object.height / 8
    for row = 0, rows - 1 do
      for column = 0, columns - 1 do
        local tileColumn = object.flipH and columns - 1 - column or column
        local tileRow = object.flipV and rows - 1 - row or row
        blitTile(
          rgba,
          width,
          char,
          object.x - minX + column * 8,
          object.y - minY + row * 8,
          object.tile + tileRow * columns + tileColumn,
          objectPalette,
          0,
          object.flipH,
          object.flipV
        )
      end
    end
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function renderAnimations(char, colors, cells, animation, animationIndex, paletteOverride)
  -- `paletteOverride` here is the effective 4bpp palette-number override
  -- actually applied to every rendered OAM object (see renderCell), which the
  -- caller may withhold for a resource whose override does not resolve to a
  -- valid bank in its own decoded palette data. It is invalid for 8bpp cell
  -- graphics, which always index the resource's one direct color table.
  if char.depth == 4 and paletteOverride ~= nil then
    sourceError("intro palette override is invalid for 8bpp cell graphics", { selector = paletteOverride })
  end
  local animations = {}
  if animationIndex ~= nil then
    animations[1] = animation.anims[animationIndex + 1]
    if not animations[1] then
      sourceError("intro animation index is outside the source animation table", { animationIndex = animationIndex })
    end
  else
    animations = animation.anims
  end
  local selectedFrames, bounds = {}, nil
  for _, selected in ipairs(animations) do
    for _, sourceFrame in ipairs(selected.frames) do
      if sourceFrame.duration <= 0 then
        sourceError("intro animation frame has no positive source duration", { duration = sourceFrame.duration })
      end
      local cell = cells.cells[sourceFrame.cell + 1]
      if not cell then
        sourceError("intro animation references a missing cell", { cell = sourceFrame.cell })
      end
      -- Compute transformed bounds for this frame. Translation moves the cell
      -- bounds; SRT scales around the resource-set origin before translation.
      -- For intro purposes the observed animation types are translate and affine
      -- with scale+translate. We apply translation and uniform scale around the
      -- origin (cell objects already carry their OAM offsets).
      local tx = sourceFrame.translateX or 0
      local ty = sourceFrame.translateY or 0
      local sx = sourceFrame.scaleX or 1
      local sy = sourceFrame.scaleY or 1
      local rot = sourceFrame.rotation or 0
      -- Compute cell bounds first, then apply transform to derive frame bounds.
      local cellB = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
      cellBounds(cell, cellB)
      -- Transform corners: scale around origin (0,0) then translate.
      -- Rotation, if present, rotates around origin as well.
      local corners = {
        { x = cellB.minX, y = cellB.minY },
        { x = cellB.maxX, y = cellB.minY },
        { x = cellB.minX, y = cellB.maxY },
        { x = cellB.maxX, y = cellB.maxY },
      }
      local transformedMinX, transformedMinY, transformedMaxX, transformedMaxY
      for _, pt in ipairs(corners) do
        local sxPt = pt.x * sx
        local syPt = pt.y * sy
        local rx, ry
        if rot ~= 0 then
          local rad = math.rad(rot)
          local cosR, sinR = math.cos(rad), math.sin(rad)
          rx = sxPt * cosR - syPt * sinR
          ry = sxPt * sinR + syPt * cosR
        else
          rx, ry = sxPt, syPt
        end
        rx = rx + tx
        ry = ry + ty
        if transformedMinX == nil then
          transformedMinX, transformedMinY, transformedMaxX, transformedMaxY = rx, ry, rx, ry
        else
          transformedMinX = math.min(transformedMinX, rx)
          transformedMinY = math.min(transformedMinY, ry)
          transformedMaxX = math.max(transformedMaxX, rx)
          transformedMaxY = math.max(transformedMaxY, ry)
        end
      end
      if bounds == nil then
        bounds = { minX = transformedMinX, minY = transformedMinY, maxX = transformedMaxX, maxY = transformedMaxY }
      else
        bounds.minX = math.min(bounds.minX, transformedMinX)
        bounds.minY = math.min(bounds.minY, transformedMinY)
        bounds.maxX = math.max(bounds.maxX, transformedMaxX)
        bounds.maxY = math.max(bounds.maxY, transformedMaxY)
      end
      selectedFrames[#selectedFrames + 1] = {
        cell = cell,
        duration = sourceFrame.duration,
        translateX = tx,
        translateY = ty,
        scaleX = sx,
        scaleY = sy,
        rotation = rot,
        element = sourceFrame.element or "none",
      }
    end
  end
  if #selectedFrames == 0 then
    sourceError("intro source animation is empty", { sourceOffset = 0 })
  end
  assert(bounds ~= nil)
  -- Union bounds are already transformed; snap to integer source pixels.
  bounds.minX = math.floor(bounds.minX + 0.5)
  bounds.minY = math.floor(bounds.minY + 0.5)
  bounds.maxX = math.ceil(bounds.maxX - 0.5)
  bounds.maxY = math.ceil(bounds.maxY - 0.5)
  -- The canvas must contain both all transformed pixels and the resource-set
  -- origin (0,0); otherwise a fully negative union would place the anchor
  -- outside [0,width]x[0,height] and fail manifest validation.
  bounds.minX = math.min(bounds.minX, 0)
  bounds.minY = math.min(bounds.minY, 0)
  bounds.maxX = math.max(bounds.maxX, 0)
  bounds.maxY = math.max(bounds.maxY, 0)
  local width, height = bounds.maxX - bounds.minX, bounds.maxY - bounds.minY
  if width <= 0 then
    width = 1
  end
  if height <= 0 then
    height = 1
  end
  local anchor = { x = -bounds.minX, y = -bounds.minY }
  -- Defensive clamp: rounding or an empty union must never escape the surface.
  anchor.x = math.max(0, math.min(width, anchor.x))
  anchor.y = math.max(0, math.min(height, anchor.y))
  local output = {}
  for index, selected in ipairs(selectedFrames) do
    -- For transformed frames we need per-frame rasterization with transform.
    -- Collect cell bounds and apply translation/scale per frame.
    local cell = selected.cell
    local tx, ty = selected.translateX, selected.translateY
    local sx, sy = selected.scaleX, selected.scaleY
    local rot = selected.rotation
    if tx == 0 and ty == 0 and sx == 1 and sy == 1 and rot == 0 then
      local image = renderCell(char, colors, cell, bounds, paletteOverride)
      output[index] = {
        width = width,
        height = height,
        rgba = image.rgba,
        duration = selected.duration,
        element = selected.element,
        translateX = tx,
        translateY = ty,
        scaleX = sx,
        scaleY = sy,
        rotation = rot,
      }
    else
      -- Render transformed cell into the shared union canvas.
      -- We render the cell into its own bounds then composite with transform.
      -- For translate-only (the common Oak case), offset the cell placement.
      local cellB = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
      cellBounds(cell, cellB)
      local cellW, cellH = cellB.maxX - cellB.minX, cellB.maxY - cellB.minY
      local cellImage = renderCell(char, colors, cell, cellB, paletteOverride)
      -- Create union canvas
      local rgba = newRgba(width, height)
      -- Determine dest origin for this transformed cell: its transformed min maps to bounds.min
      -- For simple translation: destX = cellB.minX + tx - bounds.minX, similarly for scale.
      -- For scaled cells we need per-pixel resampling. Oak shrink uses uniform scale near 1,
      -- so we support nearest-neighbor scaling of the cell image.
      local destMinX = math.floor(cellB.minX * sx + tx + 0.5)
      local destMinY = math.floor(cellB.minY * sy + ty + 0.5)
      -- If rotation present, bounds already account for it but per-pixel rotation
      -- needs full transform. Implement per-pixel affine mapping for correctness.
      if rot ~= 0 then
        local rad = math.rad(rot)
        local cosR, sinR = math.cos(rad), math.sin(rad)
        -- Iterate over dest canvas and sample source cell image via inverse transform.
        for dy = 0, height - 1 do
          for dx = 0, width - 1 do
            -- World coord of dest pixel
            local wx = bounds.minX + dx
            local wy = bounds.minY + dy
            -- Inverse translate then inverse rotate then inverse scale then offset to cell local
            local ix = wx - tx
            local iy = wy - ty
            local sxInv = ix * cosR + iy * sinR
            local syInv = -ix * sinR + iy * cosR
            sxInv = sxInv / sx
            syInv = syInv / sy
            local srcX = math.floor(sxInv - cellB.minX + 0.5)
            local srcY = math.floor(syInv - cellB.minY + 0.5)
            if srcX >= 0 and srcX < cellW and srcY >= 0 and srcY < cellH then
              local srcOff = (srcY * cellW + srcX) * 4
              local r = byteAt(cellImage.rgba, srcOff + 1)
              local g = byteAt(cellImage.rgba, srcOff + 2)
              local b = byteAt(cellImage.rgba, srcOff + 3)
              local a = byteAt(cellImage.rgba, srcOff + 4)
              if a ~= 0 and a ~= nil then
                local dstOff = (dy * width + dx) * 4
                rgba[dstOff + 1], rgba[dstOff + 2], rgba[dstOff + 3], rgba[dstOff + 4] = r, g, b, a
              end
            end
          end
        end
      elseif sx ~= 1 or sy ~= 1 then
        -- Nearest-neighbor scale
        for dy = 0, height - 1 do
          for dx = 0, width - 1 do
            local wx = bounds.minX + dx
            local wy = bounds.minY + dy
            local sxInv = (wx - tx) / sx
            local syInv = (wy - ty) / sy
            local srcX = math.floor(sxInv - cellB.minX + 0.5)
            local srcY = math.floor(syInv - cellB.minY + 0.5)
            if srcX >= 0 and srcX < cellW and srcY >= 0 and srcY < cellH then
              local srcOff = (srcY * cellW + srcX) * 4
              local r = byteAt(cellImage.rgba, srcOff + 1)
              local g = byteAt(cellImage.rgba, srcOff + 2)
              local b = byteAt(cellImage.rgba, srcOff + 3)
              local a = byteAt(cellImage.rgba, srcOff + 4)
              if a ~= 0 and a ~= nil then
                local dstOff = (dy * width + dx) * 4
                rgba[dstOff + 1], rgba[dstOff + 2], rgba[dstOff + 3], rgba[dstOff + 4] = r, g, b, a
              end
            end
          end
        end
      else
        -- Translate only: direct copy at translated position
        local copyOriginX = destMinX - bounds.minX
        local copyOriginY = destMinY - bounds.minY
        for sy2 = 0, cellH - 1 do
          for sx2 = 0, cellW - 1 do
            local srcOff = (sy2 * cellW + sx2) * 4
            local r = byteAt(cellImage.rgba, srcOff + 1)
            local g = byteAt(cellImage.rgba, srcOff + 2)
            local b = byteAt(cellImage.rgba, srcOff + 3)
            local a = byteAt(cellImage.rgba, srcOff + 4)
            if a ~= 0 and a ~= nil then
              local dx = copyOriginX + sx2
              local dy = copyOriginY + sy2
              if dx >= 0 and dx < width and dy >= 0 and dy < height then
                local dstOff = (dy * width + dx) * 4
                rgba[dstOff + 1], rgba[dstOff + 2], rgba[dstOff + 3], rgba[dstOff + 4] = r, g, b, a
              end
            end
          end
        end
      end
      output[index] = {
        width = width,
        height = height,
        rgba = concatBytes(rgba),
        duration = selected.duration,
        element = selected.element,
        translateX = tx,
        translateY = ty,
        scaleX = sx,
        scaleY = sy,
        rotation = rot,
      }
    end
  end
  local sourceBounds = { x = bounds.minX, y = bounds.minY, width = width, height = height }
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    frames = output,
    rgba = output[1].rgba,
  },
    output
end

local function addDependency(dependencies, archiveName, memberId, bytes, role)
  dependencies[#dependencies + 1] = {
    archive = archiveName,
    memberId = memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
end

local function u32le(bytes, offset, label)
  if offset + 4 > #bytes then
    sourceError("intro resource table is truncated", { label = label, sourceOffset = offset })
  end
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

local function readResourceTable(archive, dependencies, spec, memberId, role)
  local bytes = decodeMember(archive, memberId, role, spec.resourceResolution.archive)
  addDependency(dependencies, spec.resourceResolution.archive, memberId, bytes, role)
  local records, offset = {}, 4
  while true do
    local narcId = u32le(bytes, offset, role)
    if narcId == 0xFFFFFFFE then
      return records
    end
    local fileId = u32le(bytes, offset + 4, role)
    local objectId = u32le(bytes, offset + 12, role)
    records[objectId] = { narcId = narcId, fileId = fileId }
    offset = offset + 24
  end
end

---@param resourceDataArchive table
---@param dependencies table
---@param spec table
---@param id string
---@return table
local function resolveResourceSet(resourceDataArchive, dependencies, spec, id)
  local resolution = assert(spec.resourceResolution)
  local headerBytes = decodeMember(resourceDataArchive, resolution.header, id .. " resource header", resolution.archive)
  addDependency(dependencies, resolution.archive, resolution.header, headerBytes, id .. ":resdat-header")
  local headerOffset = spec.resourceSet * 32
  local charId = u32le(headerBytes, headerOffset, id .. " resource header")
  local paletteId = u32le(headerBytes, headerOffset + 4, id .. " resource header")
  local cellId = u32le(headerBytes, headerOffset + 8, id .. " resource header")
  local animationId = u32le(headerBytes, headerOffset + 12, id .. " resource header")
  local tables = {
    { key = "char", memberId = resolution.charTable, objectId = charId },
    { key = "palette", memberId = resolution.paletteTable, objectId = paletteId },
    { key = "cell", memberId = resolution.cellTable, objectId = cellId },
    { key = "animation", memberId = resolution.animationTable, objectId = animationId },
  }
  local resolved = {}
  for _, tableSpec in ipairs(tables) do
    local role = id .. ":resdat-" .. tableSpec.key .. "-table"
    local records = readResourceTable(resourceDataArchive, dependencies, spec, tableSpec.memberId, role)
    local record = records[tableSpec.objectId]
    if not record or record.narcId ~= resolution.sourceNarcId then
      sourceError("intro resource set references an unsupported source archive", {
        asset = id,
        resourceSet = spec.resourceSet,
        resourceId = tableSpec.objectId,
        narcId = record and record.narcId,
      })
    end
    resolved[tableSpec.key] = record.fileId
  end
  local result = {}
  for key, value in pairs(spec) do
    result[key] = value --[[@as string|integer|table]]
  end
  result.char, result.palette = resolved.char, resolved.palette
  result.cell, result.animation = resolved.cell, resolved.animation
  return result
end

local function assetPath(id)
  return IntroAssetCache.assetDir() .. "/" .. id:gsub("%.", "-") .. ".png"
end

local function addAsset(manifest, assets, id, image, frames, sourceBounds, anchor, provenance, sourceCenter)
  sourceBounds = sourceBounds or { x = 0, y = 0, width = image.width, height = image.height }
  anchor = anchor or { x = image.width / 2, y = image.height }
  if
    type(anchor) ~= "table"
    or type(anchor.x) ~= "number"
    or type(anchor.y) ~= "number"
    or anchor.x ~= anchor.x
    or anchor.y ~= anchor.y
    or anchor.x < 0
    or anchor.x > image.width
    or anchor.y < 0
    or anchor.y > image.height
  then
    sourceError("intro asset anchor is outside its generated surface", { asset = id })
  end
  local paths = {}
  for index, frame in ipairs(frames) do
    paths[index] = assetPath(id .. "." .. index)
    assets[paths[index]] = PngWriter.encode(frame.width, frame.height, frame.rgba)
  end
  local widget = {
    image = paths[1],
    width = image.width,
    height = image.height,
    anchor = anchor,
    sourceBounds = sourceBounds,
    sampling = "nearest",
    provenance = provenance,
    frames = {},
  }
  if sourceCenter then
    widget.sourceCenter = sourceCenter
  end
  for index, frame in ipairs(frames) do
    widget.frames[index] = {
      image = paths[index],
      width = frame.width,
      height = frame.height,
      duration = frame.duration,
      anchor = anchor,
      element = frame.element or "none",
      translateX = frame.translateX or 0,
      translateY = frame.translateY or 0,
      scaleX = frame.scaleX or 1,
      scaleY = frame.scaleY or 1,
      rotation = frame.rotation or 0,
    }
  end
  manifest.widgets[id] = widget
end

local loadCharPalette

-- `spec.paletteOverride` is the pinned source template selector and is always
-- the provenance-recorded palette fact for this resource. `disableRasterOverride`
-- lets a caller withhold that value from actual rasterization for a resource
-- whose own decoded palette data does not populate a bank at that slot (the
-- sprite system's palette-number overwrite addresses a shared VRAM offset
-- assigned when the sprite is created, not necessarily a bank inside this
-- resource's own NCLR data); rasterization then falls back to each object's
-- own decoded OAM palette field while provenance still records the source fact.
local function compileCellAnimation(archive, dependencies, manifest, assets, id, spec, disableRasterOverride)
  local dependencyRole = id:gsub("_", "-")
  local char, palette = loadCharPalette(archive, dependencies, spec, dependencyRole)
  local cellBytes = decodeMember(archive, spec.cell, id .. " cell", spec.archive)
  local animationBytes = decodeMember(archive, spec.animation, id .. " animation", spec.archive)
  addDependency(dependencies, spec.archive, spec.cell, cellBytes, dependencyRole .. ":cell")
  addDependency(dependencies, spec.archive, spec.animation, animationBytes, dependencyRole .. ":animation")
  local cells = decode("decodeCell", cellBytes, id .. " cell", spec.cell, spec.archive)
  local animation = decode("decodeAnimation", animationBytes, id .. " animation", spec.animation, spec.archive)
  ---@type string|integer|table|nil
  local rasterPaletteOverride = spec.paletteOverride
  if disableRasterOverride then
    rasterPaletteOverride = nil
  end
  local image, frames =
    renderAnimations(char, palette.colors, cells, animation, spec.animationIndex, rasterPaletteOverride)
  addAsset(manifest, assets, id, image, frames, image.sourceBounds, image.anchor, {
    resourceSet = spec.resourceSet,
    paletteSlot = spec.paletteOverride,
    rule = "stable-oam-origin",
  }, spec.sourceCenter)
end

local function loadCharPaletteImpl(archive, dependencies, spec, role)
  local archiveName = spec.archive or config.archive
  local charBytes = decodeMember(archive, spec.char, role .. " char", archiveName)
  local paletteBytes = decodeMember(archive, spec.palette, role .. " palette", archiveName)
  addDependency(dependencies, archiveName, spec.char, charBytes, role .. ":char")
  addDependency(dependencies, archiveName, spec.palette, paletteBytes, role .. ":palette")
  return decode("decodeChar", charBytes, role .. " char", spec.char, archiveName),
    decode("decodePalette", paletteBytes, role .. " palette", spec.palette, archiveName)
end

loadCharPalette = loadCharPaletteImpl

local function compileSingle(archive, dependencies, manifest, assets, id, spec, dependencyRole)
  dependencyRole = dependencyRole or id
  local char, palette = loadCharPalette(archive, dependencies, spec, dependencyRole)
  local image = renderChar(char, palette.colors)
  if spec.screen then
    local screenBytes = decodeMember(archive, spec.screen, dependencyRole .. " screen", spec.archive or config.archive)
    addDependency(dependencies, spec.archive or config.archive, spec.screen, screenBytes, dependencyRole .. ":screen")
    local screen =
      decode("decodeScreen", screenBytes, dependencyRole .. " screen", spec.screen, spec.archive or config.archive)
    image = renderScreen(char, palette.colors, screen)
  end
  local cropped = IntroAssetImage.cropAlphaUnion({ image }, { x = image.width / 2, y = image.height })
  addAsset(
    manifest,
    assets,
    id,
    cropped,
    { { width = cropped.width, height = cropped.height, rgba = cropped.frames[1].rgba, duration = 1 } },
    cropped.sourceBounds,
    cropped.anchor,
    { rule = "alpha-crop-bottom-center" }
  )
end

local function compileShrink(archive, dependencies, manifest, assets, id, spec)
  -- Shrink frames are the portrait screen (NSCR 9) rendered with each
  -- replacement NCGR. This matches OakSpeech_DrawPicOnBgLayer which loads
  -- the portrait char then its screen map (member 9) and reuses that mapping
  -- for every shrink replacement.
  local screenMember = spec.screen or 9
  local screenBytes = decodeMember(archive, screenMember, id .. " screen", spec.archive or config.archive)
  addDependency(dependencies, spec.archive or config.archive, screenMember, screenBytes, id .. ":screen")
  local screen = decode("decodeScreen", screenBytes, id .. " screen", screenMember, spec.archive or config.archive)
  local images, width = {}, nil
  for frameIndex, charMember in ipairs(spec.chars) do
    local charBytes = decodeMember(archive, charMember, id .. " char " .. frameIndex, spec.archive or config.archive)
    local paletteBytes =
      decodeMember(archive, spec.palette, id .. " palette " .. frameIndex, spec.archive or config.archive)
    if frameIndex == 1 then
      addDependency(dependencies, spec.archive or config.archive, spec.palette, paletteBytes, id .. ":palette")
    end
    addDependency(dependencies, spec.archive or config.archive, charMember, charBytes, id .. ":char:" .. frameIndex)
    local char =
      decode("decodeChar", charBytes, id .. " char " .. frameIndex, charMember, spec.archive or config.archive)
    local palette = decode(
      "decodePalette",
      paletteBytes,
      id .. " palette " .. frameIndex,
      spec.palette,
      spec.archive or config.archive
    )
    local image = renderScreen(char, palette.colors, screen)
    if width ~= nil and image.width ~= width then
      sourceError("intro shrink frames have inconsistent dimensions", { asset = id, memberId = charMember })
    end
    width = width or image.width
    images[#images + 1] = image
  end
  local cropped = IntroAssetImage.cropAlphaUnion(images, { x = width / 2, y = images[1].height })
  local frames = {}
  for frameIndex, image in ipairs(cropped.frames) do
    frames[frameIndex] = {
      width = cropped.width,
      height = cropped.height,
      rgba = image.rgba,
      duration = SHRINK_FRAME_DURATION,
    }
  end
  addAsset(
    manifest,
    assets,
    id,
    cropped,
    frames,
    cropped.sourceBounds,
    cropped.anchor,
    { rule = "portrait-screen-alpha-union", screenMember = screenMember, paletteMember = spec.palette }
  )
end

-- OakSpeech_BlinkHighlightedGenderFrame (src/oaks_speech.c) rewrites two
-- palette entries per gender button on the gender-selector background layer:
-- a "pulse tone" entry that sine-modulates when selected, and an "accent"
-- entry that becomes red when selected or gray when not. Both live in bank 0
-- of the selector's own loaded palette (sButtonBlinkPalOffsets = {12, 14}).
local GENDER_SELECTOR_MASK_TARGETS = {
  { gender = "male", kind = "pulseMask", bank = 0, value = 12 },
  { gender = "male", kind = "accentMask", bank = 0, value = 13 },
  { gender = "female", kind = "pulseMask", bank = 0, value = 14 },
  { gender = "female", kind = "accentMask", bank = 0, value = 15 },
}

local GENDER_SELECTOR_BACKGROUND_BANK = 3

-- Decode every bank-0 screen entry's per-pixel source color indices without
-- yet deciding chrome membership, and note which entries directly carry a
-- dynamic frame-semantic value (the pulse/accent palette entries HGSS's
-- blink routine rewrites for the selected gender frame). Bank-3 entries are
-- background by construction and are neither decoded nor considered.
local function decodeGenderSelectorBankZeroEntries(char, screen, targetsByValue)
  local tileBytes = 32
  local tileCount = #char.tiles / tileBytes
  local width, height = screen.width, screen.height
  local columns = width / 8
  local entryPixels, dynamicEntries = {}, {}
  for index, entry in ipairs(screen.entries) do
    if entry.palette ~= 0 and entry.palette ~= GENDER_SELECTOR_BACKGROUND_BANK then
      sourceError("intro gender selector uses an unknown palette bank", { palette = entry.palette })
    end
    if entry.tile < 0 or entry.tile >= tileCount then
      sourceError("intro gender selector screen references a missing tile", { tile = entry.tile })
    end
    if entry.palette == 0 then
      local base = entry.tile * tileBytes
      local pixels = {}
      for tileRow = 0, 7 do
        for pairColumn = 0, 3 do
          local byte = string.byte(char.tiles, base + tileRow * 4 + pairColumn + 1)
          local values = { byte % 16, math.floor(byte / 16) }
          for pairOffset, value in ipairs(values) do
            local localX = pairColumn * 2 + (pairOffset - 1)
            local targetX = entry.flipH and 7 - localX or localX
            local targetY = entry.flipV and 7 - tileRow or tileRow
            pixels[#pixels + 1] = { x = targetX, y = targetY, value = value }
            if targetsByValue[value] then
              dynamicEntries[index] = true
            end
          end
        end
      end
      entryPixels[index] = pixels
    end
  end
  return entryPixels, dynamicEntries, columns, height / 8
end

-- A bank-0 tile instance belongs to a selector frame only when it itself
-- carries a dynamic frame-semantic pixel value, or when it is directly
-- tile-grid-adjacent to one that does. Adjacency is checked only against the
-- dynamic entries themselves (not transitively through other newly admitted
-- static neighbors), so a long unbroken run of unrelated bank-0 backing that
-- merely touches the frame's outermost ring at one edge cannot ride that
-- single contact into full-row/full-column membership; only the frame's own
-- immediate static border tiles are picked up this way. Background-bank (3)
-- entries are never candidates.
local function floodFillGenderSelectorFrameMembers(entryPixels, dynamicEntries, columns, rows)
  local member = {}
  for index in pairs(dynamicEntries) do
    member[index] = true
  end
  for index in pairs(entryPixels) do
    if not member[index] then
      local zero = index - 1
      local row, column = math.floor(zero / columns), zero % columns
      for _, delta in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
        local nRow, nColumn = row + delta[1], column + delta[2]
        if nRow >= 0 and nRow < rows and nColumn >= 0 and nColumn < columns then
          local neighborIndex = nRow * columns + nColumn + 1
          if dynamicEntries[neighborIndex] then
            member[index] = true
            break
          end
        end
      end
    end
  end
  return member
end

local function classifyGenderSelectorMasks(char, screen)
  if char.depth ~= 3 then
    sourceError("gender selector background requires 4bpp source tiles", { depth = char.depth })
  end
  local width, height = screen.width, screen.height
  local masks = {}
  local chrome = newRgba(width, height)
  local targetsByValue = {}
  for _, target in ipairs(GENDER_SELECTOR_MASK_TARGETS) do
    masks[target.gender] = masks[target.gender] or {}
    masks[target.gender][target.kind] = newRgba(width, height)
    assert(target.bank == 0, "gender selector dynamic frame entries are defined on bank 0")
    targetsByValue[target.value] = target
  end
  local entryPixels, dynamicEntries, columns, rows = decodeGenderSelectorBankZeroEntries(char, screen, targetsByValue)
  local frameMembers = floodFillGenderSelectorFrameMembers(entryPixels, dynamicEntries, columns, rows)
  for index in pairs(frameMembers) do
    local zero = index - 1
    local row, column = math.floor(zero / columns), zero % columns
    for _, pixel in ipairs(entryPixels[index]) do
      local px, py = column * 8 + pixel.x, row * 8 + pixel.y
      local offset = (py * width + px) * 4
      local target = targetsByValue[pixel.value]
      if target then
        local mask = masks[target.gender][target.kind]
        mask[offset + 1], mask[offset + 2], mask[offset + 3], mask[offset + 4] = 255, 255, 255, 255
      elseif pixel.value ~= 0 then
        chrome[offset + 4] = 255
      end
    end
  end
  return masks, chrome, width, height
end

local function compileGenderSelector(archive, dependencies, manifest, assets, spec)
  local char, palette = loadCharPalette(archive, dependencies, spec, "gender-selector")
  local screenBytes = decodeMember(archive, spec.screen, "gender selector screen", spec.archive)
  addDependency(dependencies, spec.archive, spec.screen, screenBytes, "gender-selector:screen")
  local screen = decode("decodeScreen", screenBytes, "gender selector screen", spec.screen, spec.archive)
  local masks, chrome, width, height = classifyGenderSelectorMasks(char, screen)
  local rendered = renderScreen(char, palette.colors, screen)
  local neutral = {}
  for offset = 1, #rendered.rgba, 4 do
    neutral[offset] = string.byte(rendered.rgba, offset)
    neutral[offset + 1] = string.byte(rendered.rgba, offset + 1)
    neutral[offset + 2] = string.byte(rendered.rgba, offset + 2)
    neutral[offset + 3] = chrome[offset + 3]
  end
  local neutralPath = IntroAssetCache.assetDir() .. "/gender-selector-neutral.png"
  assets[neutralPath] = PngWriter.encode(width, height, concatBytes(neutral))

  local buttons = {}
  for _, gender in ipairs({ "male", "female" }) do
    local button, unionBounds = {}, nil
    for _, kind in ipairs({ "pulseMask", "accentMask" }) do
      local surface = { width = width, height = height, rgba = concatBytes(masks[gender][kind]) }
      local cropped = IntroAssetImage.cropAlphaUnion({ surface }, { x = width / 2, y = height / 2 })
      local path = assetPath("gender-selector-" .. gender .. "-" .. kind)
      assets[path] = PngWriter.encode(cropped.width, cropped.height, cropped.frames[1].rgba)
      button[kind] = {
        image = path,
        width = cropped.width,
        height = cropped.height,
        bounds = cropped.sourceBounds,
      }
      local b = cropped.sourceBounds
      if unionBounds == nil then
        unionBounds = { minX = b.x, minY = b.y, maxX = b.x + b.width, maxY = b.y + b.height }
      else
        unionBounds.minX = math.min(unionBounds.minX, b.x)
        unionBounds.minY = math.min(unionBounds.minY, b.y)
        unionBounds.maxX = math.max(unionBounds.maxX, b.x + b.width)
        unionBounds.maxY = math.max(unionBounds.maxY, b.y + b.height)
      end
    end
    button.bounds = {
      x = unionBounds.minX,
      y = unionBounds.minY,
      width = unionBounds.maxX - unionBounds.minX,
      height = unionBounds.maxY - unionBounds.minY,
    }
    buttons[gender] = button
  end

  local defaultToneColor = palette.colors[13]
  if not defaultToneColor then
    sourceError("gender selector default tone palette entry is missing", {})
  end
  manifest.genderSelector = {
    neutral = { image = neutralPath, width = width, height = height },
    defaultTone = { r = defaultToneColor.r, g = defaultToneColor.g, b = defaultToneColor.b },
    buttons = buttons,
  }
end

local function sourceArchive(romFs, archiveName)
  local archive, err = romFs:openNarc(archiveName)
  if not archive then
    sourceError("source intro archive is unavailable: " .. tostring(err), { archive = archiveName, sourceOffset = 0 })
  end
  return archive
end

---@param romFs table RomFs-shaped source reader
---@return table bundle
function IntroAssetCompiler.compile(romFs)
  assert(
    romFs and type(romFs.metadata) == "function" and type(romFs.openNarc) == "function",
    "intro compilation requires source metadata and archive reader"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "intro source metadata must carry sha1")
  local variant = assert(type(romFs.version) == "function" and romFs:version(), "intro source variant is required")
  local paletteMember = config.variant(variant)
  local backgroundSpec = { char = config.background.char, palette = paletteMember, screen = config.background.screen }
  local archive = sourceArchive(romFs, config.archive)
  local resourceResolution = config.ball_open.resourceResolution
  local resourceDataArchive = sourceArchive(romFs, resourceResolution.archive)
  local dependencies, assets = {}, {}
  local manifest = {
    schemaVersion = 5,
    variant = variant,
    sourceReference = { width = 256, height = 192 },
    widgets = {},
  }

  local backgroundChar, backgroundPalette = loadCharPalette(archive, dependencies, backgroundSpec, "background")
  local backgroundBytes = decodeMember(archive, config.background.screen, "background screen", config.archive)
  addDependency(dependencies, config.archive, config.background.screen, backgroundBytes, "background:screen")
  local backgroundScreen =
    decode("decodeScreen", backgroundBytes, "background screen", config.background.screen, config.archive)
  local renderedBackground = renderScreen(backgroundChar, backgroundPalette.colors, backgroundScreen)
  local gradient =
    IntroAssetImage.reduceGradient(renderedBackground.width, renderedBackground.height, renderedBackground.rgba)
  local backgroundPath = IntroAssetCache.assetDir() .. "/background.png"
  assets[backgroundPath] = PngWriter.encode(gradient.width, gradient.height, gradient.rgba)
  manifest.background = {
    image = backgroundPath,
    width = 1,
    height = 192,
    sampling = "linear",
    provenance = { charMember = 0, screenMember = 3, paletteMember = paletteMember },
  }

  compileSingle(archive, dependencies, manifest, assets, "oak", config.oak)
  compileSingle(archive, dependencies, manifest, assets, "male", config.gender.male)
  compileSingle(archive, dependencies, manifest, assets, "female", config.gender.female)
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    local spec = config.genderSelectors[id:gsub("gender_", "")]
    -- Both selector resources' own shipped NCLR data only populates bank 0;
    -- every other bank is all-zero, so the configured template slot (0 for
    -- male, 1 for female) does not address real chromatic data for female.
    -- Each object's own decoded OAM palette field (bank 0 for both) is the
    -- one populated bank in both files, matching the ball/Marill resource's
    -- same VRAM-offset situation, so rasterization falls back to it here too.
    compileCellAnimation(
      archive,
      dependencies,
      manifest,
      assets,
      id,
      resolveResourceSet(resourceDataArchive, dependencies, spec, id),
      true
    )
  end
  local genderBackgroundPalette = config.genderBackground.palettes[variant]
  local genderBackground = {
    archive = config.archive,
    char = config.genderBackground.char,
    palette = genderBackgroundPalette,
    screen = config.genderBackground.screen,
  }
  compileSingle(archive, dependencies, manifest, assets, "gender_background", genderBackground, "gender-background")
  compileGenderSelector(archive, dependencies, manifest, assets, genderBackground)
  compileShrink(archive, dependencies, manifest, assets, "shrink_male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink_female", config.shrink.female)
  local ballArchive = sourceArchive(romFs, config.ball_open.archive)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local spec = assert(config[id])
    assert(type(spec) == "table")
    ---@cast spec table
    local resolved = resolveResourceSet(resourceDataArchive, dependencies, spec, id)
    -- This resource set's own decoded palette holds no populated colors at
    -- the pinned template slot: the sprite system's palette-number overwrite
    -- applies to a VRAM bank offset assigned when the sprite is created
    -- (Sprite_GetPalIndex at creation time, added to the template's local
    -- .pal value), not to a slot inside this resource's own palette data
    -- starting at zero. That VRAM offset depends on other sprites already
    -- loaded onto the same 2D engine and is not recoverable from this
    -- resource's own header. Each object's own decoded palette-bank field
    -- remains the correct, ROM-verified color selector here (the gender
    -- selectors below share this same fallback, for the same reason: their
    -- own shipped palette data is likewise unpopulated past bank 0). The
    -- pinned template value still belongs in provenance (compileCellAnimation
    -- records spec.paletteOverride there regardless), so it is not cleared
    -- here.
    compileCellAnimation(ballArchive, dependencies, manifest, assets, id, resolved, true)
  end

  local valid, err = IntroAssetCache.validateManifest(manifest)
  if not valid then
    assert(err)
    sourceError("compiled intro manifest is invalid: " .. err.message, { cause = err.code, sourceOffset = 0 })
  end
  return {
    marker = IntroAssetCache.marker(metadata.sha1, Hashing.hashLua(dependencies)),
    manifest = manifest,
    dependencies = {
      schema = "g4-intro-provenance-v1",
      source = config.provenance,
      dependencies = dependencies,
    },
    assets = assets,
  }
end

return IntroAssetCompiler
