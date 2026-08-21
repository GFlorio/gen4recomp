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

local function renderCell(char, palette, cell)
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
          object.palette,
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
  local images, frames, width, height = {}, {}, 0, 0
  for _, selected in ipairs(animations) do
    for _, sourceFrame in ipairs(selected.frames) do
      if sourceFrame.duration <= 0 then
        sourceError("intro animation frame has no positive source duration", { duration = sourceFrame.duration })
      end
      local cell = cells.cells[sourceFrame.cell + 1]
      if not cell then
        sourceError("intro animation references a missing cell", { cell = sourceFrame.cell })
      end
      local image = renderCell(char, palette, cell)
      images[#images + 1] = image
      width = math.max(width, image.width)
      height = height + image.height
      frames[#frames + 1] = {
        x = 0,
        y = height - image.height,
        width = image.width,
        height = image.height,
        duration = sourceFrame.duration,
      }
    end
  end
  if #images == 0 then
    sourceError("intro source animation is empty", { sourceOffset = 0 })
  end
  local rgba, y = newRgba(width, height), 0
  for _, image in ipairs(images) do
    for row = 0, image.height - 1 do
      local source, destination = row * image.width * 4 + 1, (y + row) * width * 4 + 1
      for offset = 0, image.width * 4 - 1 do
        rgba[destination + offset] = string.byte(image.rgba, source + offset)
      end
    end
    y = y + image.height
  end
  return { width = width, height = height, rgba = concatBytes(rgba) }, frames
end

local function addDependency(dependencies, archiveName, memberId, bytes, role)
  dependencies[#dependencies + 1] = {
    archive = archiveName,
    memberId = memberId,
    role = role,
    sha1 = Hashing.sha1hex(bytes),
  }
end

local function assetPath(id)
  return IntroAssetCache.assetDir() .. "/" .. id:gsub("%.", "-") .. ".png"
end

local function addAsset(manifest, assets, id, image, frames)
  local path = assetPath(id)
  manifest.assets[id] = {
    image = path,
    width = image.width,
    height = image.height,
    frames = frames,
    filter = "nearest",
  }
  assets[path] = PngWriter.encode(image.width, image.height, image.rgba)
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

local function compileSingle(archive, dependencies, manifest, assets, id, spec)
  local char, palette = loadCharPalette(archive, dependencies, spec, id)
  local image = renderChar(char, palette.colors)
  if spec.screen then
    local screenBytes = decodeMember(archive, spec.screen, id .. " screen", spec.archive or config.archive)
    addDependency(dependencies, spec.archive or config.archive, spec.screen, screenBytes, id .. ":screen")
    local screen = decode("decodeScreen", screenBytes, id .. " screen", spec.screen, spec.archive or config.archive)
    image = renderScreen(char, palette.colors, screen)
  end
  addAsset(manifest, assets, id, image, {
    { x = 0, y = 0, width = image.width, height = image.height, duration = 1 },
  })
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
  local rgba, frames, y = newRgba(width, height), {}, 0
  for frameIndex, image in ipairs(images) do
    for row = 0, image.height - 1 do
      local source, destination = row * image.width * 4 + 1, (y + row) * width * 4 + 1
      for offset = 0, image.width * 4 - 1 do
        rgba[destination + offset] = string.byte(image.rgba, source + offset)
      end
    end
    frames[frameIndex] = {
      x = 0,
      y = y,
      width = image.width,
      height = image.height,
      duration = frameIndex == 1 and 1 or 4,
    }
    y = y + image.height
  end
  addAsset(manifest, assets, id, { width = width, height = height, rgba = concatBytes(rgba) }, frames)
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
  local archive = sourceArchive(romFs, config.archive)
  local dependencies, assets = {}, {}
  local manifest = {
    schema = IntroAssetCache.SCHEMA,
    reference = { width = 256, height = 192, filter = "nearest" },
    assets = {},
  }

  local backgroundChar, backgroundPalette = loadCharPalette(archive, dependencies, config.background, "background")
  local backgroundBytes = decodeMember(archive, config.background.screen, "background screen", config.archive)
  addDependency(dependencies, config.archive, config.background.screen, backgroundBytes, "background:screen")
  local backgroundScreen =
    decode("decodeScreen", backgroundBytes, "background screen", config.background.screen, config.archive)
  addAsset(manifest, assets, "background", renderScreen(backgroundChar, backgroundPalette.colors, backgroundScreen), {
    { x = 0, y = 0, width = 256, height = 192, duration = 1 },
  })

  compileSingle(archive, dependencies, manifest, assets, "oak", config.oak)
  local marillChar, marillPalette = loadCharPalette(archive, dependencies, config.marill, "marill")
  local marillCellBytes = decodeMember(archive, config.marill.cell, "marill cell", config.archive)
  local marillAnimationBytes = decodeMember(archive, config.marill.animation, "marill animation", config.archive)
  addDependency(dependencies, config.archive, config.marill.cell, marillCellBytes, "marill:cell")
  addDependency(dependencies, config.archive, config.marill.animation, marillAnimationBytes, "marill:animation")
  local marillCells = decode("decodeCell", marillCellBytes, "marill cell", config.marill.cell, config.archive)
  local marillAnimation =
    decode("decodeAnimation", marillAnimationBytes, "marill animation", config.marill.animation, config.archive)
  local marill, marillFrames =
    renderAnimations(marillChar, marillPalette.colors, marillCells, marillAnimation, config.marill.animationIndex)
  addAsset(manifest, assets, "marill", marill, marillFrames)
  compileSingle(archive, dependencies, manifest, assets, "gender.male", config.gender.male)
  compileSingle(archive, dependencies, manifest, assets, "gender.female", config.gender.female)
  compileSingle(archive, dependencies, manifest, assets, "gender.indicator", config.gender.indicator)
  compileShrink(archive, dependencies, manifest, assets, "shrink.male", config.shrink.male)
  compileShrink(archive, dependencies, manifest, assets, "shrink.female", config.shrink.female)

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
