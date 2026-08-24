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

local function renderCell(char, palette, cell, paletteOverride)
  local minX, minY, maxX, maxY
  for _, object in ipairs(cell.objs) do
    minX = math.min(minX or object.x, object.x)
    minY = math.min(minY or object.y, object.y)
    maxX = math.max(maxX or object.x + object.width, object.x + object.width)
    maxY = math.max(maxY or object.y + object.height, object.y + object.height)
  end
  if not minX then
    sourceError("intro cell has no objects", { sourceOffset = 0 })
  end
  local width, height = maxX - minX, maxY - minY
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
          paletteOverride == nil and object.palette or paletteOverride,
          object.flipH,
          object.flipV
        )
      end
    end
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }
end

local function padSurface(image, width, height)
  if image.width == width and image.height == height then
    return image
  end
  local rows = {}
  local empty = string.rep(string.char(0, 0, 0, 0), width)
  for y = 0, height - 1 do
    local row = y < image.height and string.sub(image.rgba, y * image.width * 4 + 1, (y + 1) * image.width * 4) or ""
    rows[#rows + 1] = row .. string.sub(empty, #row + 1)
  end
  return { width = width, height = height, rgba = table.concat(rows) }
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
  local images, frames, width, stackHeight, maxHeight = {}, {}, 0, 0, 0
  for _, selected in ipairs(animations) do
    for _, sourceFrame in ipairs(selected.frames) do
      if sourceFrame.duration <= 0 then
        sourceError("intro animation frame has no positive source duration", { duration = sourceFrame.duration })
      end
      local cell = cells.cells[sourceFrame.cell + 1]
      if not cell then
        sourceError("intro animation references a missing cell", { cell = sourceFrame.cell })
      end
      local image = renderCell(char, palette, cell, paletteOverride)
      images[#images + 1] = image
      width = math.max(width, image.width)
      stackHeight = stackHeight + image.height
      maxHeight = math.max(maxHeight, image.height)
      frames[#frames + 1] = {
        x = 0,
        y = stackHeight - image.height,
        width = image.width,
        height = image.height,
        duration = sourceFrame.duration,
      }
    end
  end
  if #images == 0 then
    sourceError("intro source animation is empty", { sourceOffset = 0 })
  end
  for index, image in ipairs(images) do
    images[index] = padSurface(image, width, maxHeight)
  end
  local frameHeight = images[1].height
  local cropped = IntroAssetImage.cropAlphaUnion(images, { x = width / 2, y = frameHeight })
  local output = {}
  for index, image in ipairs(cropped.frames) do
    output[index] =
      { width = cropped.width, height = cropped.height, rgba = image.rgba, duration = frames[index].duration }
  end
  return cropped, output
end

local function addDependency(dependencies, archiveName, memberId, bytes, role)
  dependencies[#dependencies + 1] = {
    archive = archiveName,
    memberId = memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
end

local function addConfiguredDependency(archive, dependencies, spec, role, memberId)
  local bytes = decodeMember(archive, memberId, role, spec.archive)
  addDependency(dependencies, spec.archive, memberId, bytes, role)
end

local function assetPath(id)
  return IntroAssetCache.assetDir() .. "/" .. id:gsub("%.", "-") .. ".png"
end

local function addAsset(manifest, assets, id, image, frames, sourceBounds, anchor, provenance, sourceCenter)
  sourceBounds = sourceBounds or { x = 0, y = 0, width = image.width, height = image.height }
  anchor = anchor or { x = image.width / 2, y = image.height }
  anchor = {
    x = math.max(0, math.min(image.width, anchor.x or image.width / 2)),
    y = math.max(0, math.min(image.height, anchor.y or image.height)),
  }
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

local function loadCharPalette(archive, dependencies, spec, role)
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
    frames[frameIndex] =
      { width = cropped.width, height = cropped.height, rgba = image.rgba, duration = frameIndex == 1 and 1 or 4 }
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
  local genderBackgroundPalette = config.genderBackground.palettes[variant]
  local genderBackground = {
    archive = config.archive,
    char = config.genderBackground.char,
    palette = genderBackgroundPalette,
    screen = config.genderBackground.screen,
  }
  compileSingle(archive, dependencies, manifest, assets, "gender_background", genderBackground, "gender-background")
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    compileSingle(archive, dependencies, manifest, assets, id, config.genderSelectors[id:gsub("gender_", "")])
    local spec = config.genderSelectors[id:gsub("gender_", "")]
    manifest.widgets[id].provenance = { resourceSet = spec.resourceSet, rule = "source-selector" }
  end
  compileShrink(archive, dependencies, manifest, assets, "shrink_male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink_female", config.shrink.female)
  local ballArchive = sourceArchive(romFs, config.ball_open.archive)
  local resolution = config.ball_open.resourceResolution
  local resourceDataArchive = sourceArchive(romFs, resolution.archive)
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    local spec = config.genderSelectors[id:gsub("gender_", "")]
    addConfiguredDependency(
      resourceDataArchive,
      dependencies,
      resolution,
      id:gsub("_", "-") .. ":resource-set",
      spec.resourceSet
    )
  end
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local spec = config[id]
    addConfiguredDependency(resourceDataArchive, dependencies, resolution, id .. ":resdat-header", resolution.header)
    addConfiguredDependency(
      resourceDataArchive,
      dependencies,
      resolution,
      id .. ":resdat-char-table",
      resolution.charTable
    )
    addConfiguredDependency(
      resourceDataArchive,
      dependencies,
      resolution,
      id .. ":resdat-palette-table",
      resolution.paletteTable
    )
    addConfiguredDependency(
      resourceDataArchive,
      dependencies,
      resolution,
      id .. ":resdat-cell-table",
      resolution.cellTable
    )
    addConfiguredDependency(
      resourceDataArchive,
      dependencies,
      resolution,
      id .. ":resdat-animation-table",
      resolution.animationTable
    )
    local char, palette = loadCharPalette(ballArchive, dependencies, spec, id)
    local cellBytes = decodeMember(ballArchive, spec.cell, id .. " cell", spec.archive)
    local animationBytes = decodeMember(ballArchive, spec.animation, id .. " animation", spec.archive)
    addDependency(dependencies, spec.archive, spec.cell, cellBytes, id .. ":cell")
    addDependency(dependencies, spec.archive, spec.animation, animationBytes, id .. ":animation")
    local cells = decode("decodeCell", cellBytes, id .. " cell", spec.cell, spec.archive)
    local animation = decode("decodeAnimation", animationBytes, id .. " animation", spec.animation, spec.archive)
    local image, frames =
      renderAnimations(char, palette.colors, cells, animation, spec.animationIndex, spec.paletteOverride)
    addAsset(manifest, assets, id, image, frames, image.sourceBounds, image.anchor, {
      resourceSet = spec.resourceSet,
      rule = "alpha-union-crop-center",
    }, spec.sourceCenter)
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
