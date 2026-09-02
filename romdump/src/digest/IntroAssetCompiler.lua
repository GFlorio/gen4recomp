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

local function renderScreen(char, palette, screen, paletteBankOverride)
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
        paletteBankOverride or entry.palette,
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

local function renderCell(char, palette, cell, bounds)
  if #cell.objs == 0 then
    sourceError("intro cell has no objects", { sourceOffset = 0 })
  end
  local minX, minY = bounds.minX, bounds.minY
  local width, height = bounds.maxX - minX, bounds.maxY - minY
  local rgba = newRgba(width, height)
  for _, object in ipairs(cell.objs) do
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
          palette,
          0,
          object.flipH,
          object.flipV
        )
      end
    end
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function renderAnimations(char, palette, cells, animation, animationIndex)
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
      local image = renderCell(char, palette, cell, bounds)
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
      local cellImage = renderCell(char, palette, cell, cellB)
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
  local records, ordered, offset = {}, {}, 4
  while true do
    local narcId = u32le(bytes, offset, role)
    if narcId == 0xFFFFFFFE then
      return records, ordered, bytes
    end
    local fileId = u32le(bytes, offset + 4, role)
    local compressed = u32le(bytes, offset + 8, role)
    local objectId = u32le(bytes, offset + 12, role)
    local record = {
      narcId = narcId,
      fileId = fileId,
      compressed = compressed,
      objectId = objectId,
      vram = u32le(bytes, offset + 16, role),
      bankCount = u32le(bytes, offset + 20, role),
    }
    if records[objectId] then
      sourceError("intro resource table contains a duplicate resource id", { objectId = objectId, label = role })
    end
    records[objectId] = record
    ordered[#ordered + 1] = record
    offset = offset + 24
  end
end

---@param resourceDataArchive table
---@param dependencies table
---@param spec table
---@param id string
---@param paletteRecords table|nil
---@param paletteBytes string|nil
---@return table
local function resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes)
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
    local records
    if tableSpec.key == "palette" and paletteRecords then
      records = paletteRecords
      addDependency(dependencies, resolution.archive, tableSpec.memberId, paletteBytes, role)
    else
      records = readResourceTable(resourceDataArchive, dependencies, spec, tableSpec.memberId, role)
    end
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

local function effectivePalette(archive, dependencies, layout, id, spec)
  local ok, ownerOrError, localBank = pcall(IntroObjPaletteResolver.owner, layout, spec.vram, spec.paletteNumber)
  if not ok then
    if Errors.is(ownerOrError) then
      ---@cast ownerOrError Errors.Error
      sourceError(ownerOrError.message, ownerOrError.context)
    end
    error(ownerOrError, 0)
  end
  ---@cast ownerOrError table
  local owner = ownerOrError
  if owner.narcId ~= spec.resourceResolution.sourceNarcId then
    sourceError("intro absolute palette owner is outside the supported source archive", {
      asset = id,
      engine = spec.vram,
      paletteNumber = spec.paletteNumber,
      ownerNarcId = owner.narcId,
    })
  end
  local archiveName = spec.archive or config.archive
  local paletteBytes = decodeMember(archive, owner.fileId, id .. " effective palette", archiveName)
  addDependency(dependencies, archiveName, owner.fileId, paletteBytes, id:gsub("_", "-") .. ":palette")
  local palette = decode("decodePalette", paletteBytes, id .. " effective palette", owner.fileId, archiveName)
  local sliceOk, colorsOrError = pcall(IntroObjPaletteResolver.slice, palette.colors, 3, localBank)
  if not sliceOk then
    if Errors.is(colorsOrError) then
      ---@cast colorsOrError Errors.Error
      sourceError(colorsOrError.message, colorsOrError.context)
    end
    error(colorsOrError, 0)
  end
  ---@cast colorsOrError table[]
  return colorsOrError
end

local function buildPaletteLayout(records)
  local ok, layoutOrError = pcall(IntroObjPaletteResolver.build, records)
  if not ok then
    if Errors.is(layoutOrError) then
      ---@cast layoutOrError Errors.Error
      sourceError(layoutOrError.message, layoutOrError.context)
    end
    error(layoutOrError, 0)
  end
  ---@cast layoutOrError table
  return layoutOrError
end

local function compileCellAnimation(archive, dependencies, manifest, assets, id, spec, layout)
  local dependencyRole = id:gsub("_", "-")
  local archiveName = spec.archive or config.archive
  local charBytes = decodeMember(archive, spec.char, id .. " char", archiveName)
  addDependency(dependencies, archiveName, spec.char, charBytes, dependencyRole .. ":char")
  local char = decode("decodeChar", charBytes, id .. " char", spec.char, archiveName)
  if char.depth ~= 3 then
    sourceError("configured intro cell graphics do not support 8bpp", { asset = id, depth = char.depth })
  end
  local paletteColors = effectivePalette(archive, dependencies, layout, id, spec)
  local cellBytes = decodeMember(archive, spec.cell, id .. " cell", spec.archive)
  local animationBytes = decodeMember(archive, spec.animation, id .. " animation", spec.archive)
  addDependency(dependencies, spec.archive, spec.cell, cellBytes, dependencyRole .. ":cell")
  addDependency(dependencies, spec.archive, spec.animation, animationBytes, dependencyRole .. ":animation")
  local cells = decode("decodeCell", cellBytes, id .. " cell", spec.cell, spec.archive)
  local animation = decode("decodeAnimation", animationBytes, id .. " animation", spec.animation, spec.archive)
  local image, frames = renderAnimations(char, paletteColors, cells, animation, spec.animationIndex)
  addAsset(manifest, assets, id, image, frames, image.sourceBounds, image.anchor, {
    resourceSet = spec.resourceSet,
    paletteNumber = spec.paletteNumber,
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
  local paletteRecords, paletteOrder, paletteBytes = readResourceTable(
    resourceDataArchive,
    dependencies,
    config.ball_open,
    resourceResolution.paletteTable,
    "intro-palette-layout"
  )
  local paletteLayout = buildPaletteLayout(paletteOrder)
  local defaultToneMember = config.genderSelector.paletteMembers[variant]
  local defaultToneBytes = decodeMember(archive, defaultToneMember, "gender selector default tone", config.archive)
  addDependency(dependencies, config.archive, defaultToneMember, defaultToneBytes, "gender-selector:default-tone")
  local defaultTonePalette =
    decode("decodePalette", defaultToneBytes, "gender selector default tone", defaultToneMember, config.archive)
  local defaultTone = defaultTonePalette.colors[config.genderSelector.defaultToneEntry + 1]
  if not defaultTone then
    sourceError("gender selector default tone palette entry is missing", {
      paletteMember = defaultToneMember,
      paletteEntry = config.genderSelector.defaultToneEntry,
    })
  end
  local manifest = {
    schemaVersion = 10,
    variant = variant,
    sourceReference = { width = 256, height = 192 },
    genderSelector = {
      defaultTone = { r = defaultTone.r, g = defaultTone.g, b = defaultTone.b },
      buttons = config.genderSelector.buttons,
    },
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
    compileCellAnimation(
      archive,
      dependencies,
      manifest,
      assets,
      id,
      resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes),
      paletteLayout
    )
  end
  compileShrink(archive, dependencies, manifest, assets, "shrink_male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink_female", config.shrink.female)

  local ballArchive = sourceArchive(romFs, config.ball_open.archive)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local spec = assert(config[id])
    assert(type(spec) == "table")
    ---@cast spec table
    local resolved = resolveResourceSet(resourceDataArchive, dependencies, spec, id, paletteRecords, paletteBytes)
    compileCellAnimation(ballArchive, dependencies, manifest, assets, id, resolved, paletteLayout)
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
