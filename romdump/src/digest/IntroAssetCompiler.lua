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
local config = require("romdump.src.config.IntroAssets")

local IntroAssetCompiler = {}

IntroAssetCompiler.ERROR = { SOURCE_INVALID = "INTRO_SOURCE_INVALID" }

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
          object.palette,
          object.flipH,
          object.flipV
        )
      end
    end
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function renderAnimations(char, palette, cells, animation, animationIndex, paletteOverride)
  if paletteOverride ~= nil then
    if type(paletteOverride) ~= "number" or paletteOverride % 1 ~= 0 or paletteOverride < 0 then
      sourceError("intro palette override is invalid", { paletteOverride = paletteOverride })
    end
    if char.depth == 3 and (paletteOverride + 1) * 16 > #palette then
      sourceError("intro palette override is outside decoded palette data", { paletteOverride = paletteOverride })
    end
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
  local selectedFrames, bounds = {}, { minX = 0, minY = 0, maxX = 0, maxY = 0 }
  for _, selected in ipairs(animations) do
    for _, sourceFrame in ipairs(selected.frames) do
      if sourceFrame.duration <= 0 then
        sourceError("intro animation frame has no positive source duration", { duration = sourceFrame.duration })
      end
      local cell = cells.cells[sourceFrame.cell + 1]
      if not cell then
        sourceError("intro animation references a missing cell", { cell = sourceFrame.cell })
      end
      cellBounds(cell, bounds)
      selectedFrames[#selectedFrames + 1] = { cell = cell, duration = sourceFrame.duration }
    end
  end
  if #selectedFrames == 0 then
    sourceError("intro source animation is empty", { sourceOffset = 0 })
  end
  local width, height = bounds.maxX - bounds.minX, bounds.maxY - bounds.minY
  local anchor = { x = -bounds.minX, y = -bounds.minY }
  local output = {}
  for index, selected in ipairs(selectedFrames) do
    local image = renderCell(char, palette, selected.cell, bounds)
    output[index] = { width = width, height = height, rgba = image.rgba, duration = selected.duration }
  end
  return {
    width = width,
    height = height,
    anchor = anchor,
    sourceBounds = { x = 0, y = 0, width = width, height = height },
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
    result[key] = value
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
    widget.frames[index] =
      { image = paths[index], width = frame.width, height = frame.height, duration = frame.duration, anchor = anchor }
  end
  manifest.widgets[id] = widget
end

local loadCharPalette

local function compileCellAnimation(archive, dependencies, manifest, assets, id, spec)
  local dependencyRole = id:gsub("_", "-")
  local char, palette = loadCharPalette(archive, dependencies, spec, dependencyRole)
  local cellBytes = decodeMember(archive, spec.cell, id .. " cell", spec.archive)
  local animationBytes = decodeMember(archive, spec.animation, id .. " animation", spec.archive)
  addDependency(dependencies, spec.archive, spec.cell, cellBytes, dependencyRole .. ":cell")
  addDependency(dependencies, spec.archive, spec.animation, animationBytes, dependencyRole .. ":animation")
  local cells = decode("decodeCell", cellBytes, id .. " cell", spec.cell, spec.archive)
  local animation = decode("decodeAnimation", animationBytes, id .. " animation", spec.animation, spec.archive)
  local image, frames =
    renderAnimations(char, palette.colors, cells, animation, spec.animationIndex, spec.paletteOverride)
  addAsset(manifest, assets, id, image, frames, image.sourceBounds, image.anchor, {
    resourceSet = spec.resourceSet,
    rule = "stable-oam-origin",
  }, spec.sourceCenter)
end

loadCharPalette = function(archive, dependencies, spec, role)
  local archiveName = spec.archive or config.archive
  local charBytes = decodeMember(archive, spec.char, role .. " char", archiveName)
  local paletteBytes = decodeMember(archive, spec.palette, role .. " palette", archiveName)
  addDependency(dependencies, archiveName, spec.char, charBytes, role .. ":char")
  addDependency(dependencies, archiveName, spec.palette, paletteBytes, role .. ":palette")
  return decode("decodeChar", charBytes, role .. " char", spec.char, archiveName),
    decode("decodePalette", paletteBytes, role .. " palette", spec.palette, archiveName)
end

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
  local images, width, height = {}, nil, 0
  for frameIndex, charMember in ipairs(spec.chars) do
    local char, palette = loadCharPalette(
      archive,
      dependencies,
      { archive = spec.archive, char = charMember, palette = spec.palette },
      id .. ":" .. frameIndex
    )
    local image = renderChar(char, palette.colors)
    if width ~= nil and image.width ~= width then
      sourceError("intro shrink frames have inconsistent dimensions", { asset = id, memberId = charMember })
    end
    width = width or image.width
    images[#images + 1] = image
    height = height + image.height
  end
  local cropped = IntroAssetImage.cropAlphaUnion(images, { x = width / 2, y = images[1].height })
  local frames = {}
  for frameIndex, image in ipairs(cropped.frames) do
    frames[frameIndex] = { width = cropped.width, height = cropped.height, rgba = image.rgba, duration = 8 }
  end
  addAsset(
    manifest,
    assets,
    id,
    cropped,
    frames,
    cropped.sourceBounds,
    cropped.anchor,
    { rule = "alpha-union-crop-bottom-center" }
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
  local manifest = {
    schemaVersion = 3,
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
    compileCellAnimation(
      archive,
      dependencies,
      manifest,
      assets,
      id,
      resolveResourceSet(resourceDataArchive, dependencies, spec, id)
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
  compileShrink(archive, dependencies, manifest, assets, "shrink_male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink_female", config.shrink.female)
  local ballArchive = sourceArchive(romFs, config.ball_open.archive)
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    compileCellAnimation(
      ballArchive,
      dependencies,
      manifest,
      assets,
      id,
      resolveResourceSet(resourceDataArchive, dependencies, config[id], id)
    )
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
