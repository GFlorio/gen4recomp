-- Compiles the generated HGSS field-UI class: the Start Menu background and
-- cursor, the twenty user dialogue frames, the corpus signpost frame and
-- wayfinding graphics, and the Trainer Card front — all as decoded PNG
-- atlases and the strict g4-field-ui-v3 manifest. Source member selection
-- lives in romdump/src/config/FieldUiAssets.lua; this module owns the HGSS
-- decode and the normalized bundle. The runtime consumes only the manifest
-- and the generated files, never this module. Pure module: no love
-- dependency.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local PngWriter = require("libs.assets.src.PngWriter")
local Lz10 = require("romdump.src.digest.Lz10")
local G2dDecoder = require("romdump.src.digest.G2dDecoder")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local manifestConfig = require("romdump.src.config.FieldUiAssets")

local FieldUiCompiler = {}

local function must(value, err)
  if value == nil then
    error(err or "expected a value", 0)
  end
  return value
end

local function concatChars(chars)
  -- string.char/unpack are limited by the Lua stack; build in row chunks.
  local out = {}
  for i = 1, #chars, 4096 do
    out[#out + 1] = string.char(unpack(chars, i, math.min(i + 4095, #chars)))
  end
  return table.concat(out)
end

-- Decode a member that may be LZ10-wrapped.
local function decodeMember(archive, memberId, label)
  local bytes = must(archive:readMember(memberId), "missing member " .. memberId .. " (" .. label .. ")")
  if string.byte(bytes, 1) == 0x10 then
    local plain, lzErr = Lz10.decode(bytes)
    if not plain then
      error(lzErr, 0)
    end
    bytes = plain
  end
  return bytes
end

-- Blit one tile's pixels into an RGBA buffer. 4bpp tiles hold two pixel
-- values per byte (low nibble first); 8bpp tiles hold one. Pixel value 0 is
-- the reserved transparency slot: the HGSS UI palettes fill it with a pink
-- chroma color that the DS window/OBJ presentation never displays. Values
-- >= 1 map to palette color `value` — colors is 1-based (colors[i] = color
-- i-1), so the lookup is value + 1 within the tile's palette bank.
local function blitTile(rgba, atlasWidth, destX, destY, charData, tileIndex, palIndex, colors, flipH, flipV)
  local depth = charData.depth
  local palBase = depth == 3 and palIndex * 16 or palIndex * 256
  local tileBytes = depth == 3 and 32 or 64
  local function put(x, y, v)
    if v == 0 then
      return
    end
    local c = colors[palBase + v + 1]
    if not c then
      return
    end
    if flipH then
      x = 7 - x
    end
    if flipV then
      y = 7 - y
    end
    local px = ((destY + y) * atlasWidth + destX + x) * 4
    rgba[px + 1], rgba[px + 2], rgba[px + 3], rgba[px + 4] = c.r, c.g, c.b, 255
  end
  local base = tileIndex * tileBytes
  if depth == 3 then
    for y = 0, 7 do
      for x = 0, 3 do
        local byte = string.byte(charData.tiles, base + y * 4 + x + 1)
        put(x * 2, y, byte % 16)
        put(x * 2 + 1, y, math.floor(byte / 16))
      end
    end
  else
    for y = 0, 7 do
      for x = 0, 7 do
        put(x, y, string.byte(charData.tiles, base + y * 8 + x + 1))
      end
    end
  end
end

local function newRgba(width, height)
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  return rgba
end

-- Render a screen (BG tilemap with flips) into a PNG.
local function renderScreen(charData, palette, screen)
  local width = screen.width
  local height = screen.height
  local rgba = newRgba(width, height)
  for row = 0, screen.height / 8 - 1 do
    for col = 0, screen.width / 8 - 1 do
      local entry = screen.entries[row * (screen.width / 8) + col + 1]
      blitTile(rgba, width, col * 8, row * 8, charData, entry.tile, entry.palette, palette, entry.flipH, entry.flipV)
    end
  end
  return PngWriter.encode(width, height, concatChars(rgba))
end

-- Render a tile run (e.g. a frame's 18 tiles) into a strip atlas.
local function renderTiles(charData, palette, tileCount, atlasWidth)
  local rgba = newRgba(atlasWidth, 8)
  for tile = 0, tileCount - 1 do
    blitTile(rgba, atlasWidth, tile * 8, 0, charData, tile, 0, palette)
  end
  return PngWriter.encode(atlasWidth, 8, concatChars(rgba))
end

local function cellBounds(cell)
  local first = assert(cell.objs[1], "cell bounds require at least one object")
  local minX, minY, maxX, maxY = first.x, first.y, first.x + 8, first.y + 8
  for i = 2, #cell.objs do
    local obj = cell.objs[i]
    if obj.x < minX then
      minX = obj.x
    end
    if obj.y < minY then
      minY = obj.y
    end
    if obj.x + 8 > maxX then
      maxX = obj.x + 8
    end
    if obj.y + 8 > maxY then
      maxY = obj.y + 8
    end
  end
  return { x = minX, y = minY, width = maxX - minX, height = maxY - minY }
end

local function loadArchive(romFs, alias)
  local info = must(romFs:resolvedNarc(alias), "unresolved NARC alias " .. alias)
  local archive = must(romFs:openNarc(alias), "failed to open " .. alias)
  return info, archive, must(romFs:read(info.fileId), "missing archive bytes " .. alias)
end

local function compileStartMenu(romFs, sha1hex, deps, assets, manifestAssets)
  local info, archive, archiveBytes = loadArchive(romFs, manifestConfig.startMenu.alias)
  local cfg = manifestConfig.startMenu
  local memberBytes = {}
  local function g2d(kind, memberId, label)
    memberBytes[memberId] = decodeMember(archive, memberId, label)
    local decoded, err =
      G2dDecoder[kind](memberBytes[memberId], { label = manifestConfig.startMenu.alias .. ":" .. memberId })
    return must(decoded, err)
  end
  local charData = g2d("decodeChar", cfg.backgroundCharMember, "start menu background char")
  local screen = g2d("decodeScreen", cfg.backgroundScreenMember, "start menu background screen")
  local pal = g2d("decodePalette", cfg.backgroundPaletteMember, "start menu background palette")
  local backgroundPath = FieldUiAssetCache.assetDir() .. "/start-menu.png"
  assets[backgroundPath] = renderScreen(charData, pal.colors, screen)
  manifestAssets["hgss.start_menu.background"] = {
    image = backgroundPath,
    width = screen.width,
    height = screen.height,
  }

  local cursorChar = g2d("decodeChar", cfg.cursorCharMember, "start menu cursor char")
  local cursorPal = g2d("decodePalette", cfg.cursorPaletteMember, "start menu cursor palette")
  local cursorCell = g2d("decodeCell", cfg.cursorCellMember, "start menu cursor cell")
  local cursorAnim = g2d("decodeAnimation", cfg.cursorAnimMember, "start menu cursor animation")
  local anim = cursorAnim.anims[1]
  -- Stack every distinct cell the animation references; each frame points at
  -- its cell's row so a multi-cell cursor animates rather than repeating the
  -- first cell's sprite.
  local cellRows = {}
  local cursorFrames = {}
  local atlasWidth = 0
  local atlasHeight = 0
  for i, frame in ipairs(anim.frames) do
    local cell = cursorCell.cells[frame.cell + 1]
    if not cell then
      Errors.raise("FIELD_UI_SOURCE_INVALID", "start menu cursor animation references a missing cell", {
        cell = frame.cell,
      })
    end
    local row = cellRows[frame.cell]
    if not row then
      local bounds = cellBounds(cell)
      row = { minX = bounds.x, minY = bounds.y, y = atlasHeight, width = bounds.width, height = bounds.height }
      atlasHeight = atlasHeight + row.height
      atlasWidth = math.max(atlasWidth, row.width)
      cellRows[frame.cell] = row
    end
    cursorFrames[i] = {
      x = 0,
      y = row.y,
      width = row.width,
      height = row.height,
      duration = frame.duration,
    }
  end
  local cursorPath = FieldUiAssetCache.assetDir() .. "/start-menu-cursor.png"
  local rgba = newRgba(atlasWidth, atlasHeight)
  for cellIndex, row in pairs(cellRows) do
    for _, obj in ipairs(cursorCell.cells[cellIndex + 1].objs) do
      blitTile(
        rgba,
        atlasWidth,
        obj.x - row.minX,
        obj.y - row.minY + row.y,
        cursorChar,
        obj.tile,
        obj.palette,
        cursorPal.colors,
        obj.flipH,
        obj.flipV
      )
    end
  end
  assets[cursorPath] = PngWriter.encode(atlasWidth, atlasHeight, concatChars(rgba))
  manifestAssets["hgss.start_menu.cursor"] = { image = cursorPath, width = atlasWidth, height = atlasHeight }

  for _, memberId in ipairs({
    cfg.backgroundCharMember,
    cfg.backgroundScreenMember,
    cfg.backgroundPaletteMember,
    cfg.cursorPaletteMember,
    cfg.cursorCellMember,
    cfg.cursorAnimMember,
    cfg.cursorCharMember,
  }) do
    deps[#deps + 1] =
      { name = manifestConfig.startMenu.alias .. ":member:" .. memberId, sha1 = sha1hex(memberBytes[memberId]) }
  end
  deps[#deps + 1] = { name = manifestConfig.startMenu.alias .. ":narc", sha1 = sha1hex(archiveBytes) }

  return {
    background = { x = 0, y = 0, width = screen.width, height = screen.height },
    cursor = { frames = cursorFrames },
    slots = {
      [1] = { x = 0, y = 0, width = 128, height = 38 },
      [2] = { x = 128, y = 0, width = 128, height = 38 },
      [3] = { x = 0, y = 38, width = 128, height = 38 },
      [4] = { x = 128, y = 38, width = 128, height = 38 },
      [5] = { x = 0, y = 76, width = 128, height = 38 },
      [6] = { x = 128, y = 76, width = 128, height = 38 },
      [7] = { x = 0, y = 114, width = 128, height = 38 },
      [8] = { x = 128, y = 114, width = 128, height = 38 },
      [9] = { x = 0, y = 152, width = 128, height = 38 },
      [10] = { x = 128, y = 152, width = 128, height = 38 },
    },
  }
end

local function compileDialogueFrames(romFs, sha1hex, deps, assets, manifestAssets)
  local info, archive, archiveBytes = loadArchive(romFs, manifestConfig.dialogueFrames.alias)
  local cfg = manifestConfig.dialogueFrames
  local tilesPath = FieldUiAssetCache.assetDir() .. "/dialogue-frame-tiles.png"
  -- Pack all frames: each frame's tiles in a row, frames stacked, each frame
  -- rendered with its own palette. The tile count comes from the decoded
  -- char data (the source members carry 18 tiles each in the real dump).
  local frameChar0Bytes = decodeMember(archive, cfg.firstFrameMember, "frame 0 char")
  local frameChar0, frame0Err = G2dDecoder.decodeChar(frameChar0Bytes, { label = "frame 0 char" })
  frameChar0 = must(frameChar0, frame0Err)
  local tilesPerFrame = math.floor(#frameChar0.tiles / (frameChar0.depth == 3 and 32 or 64))
  local atlasWidth = tilesPerFrame * 8
  local atlasHeight = cfg.frameCount * 8
  local rgba = newRgba(atlasWidth, atlasHeight)
  local frameTiles = {}
  local palettes = {}
  for frame = 0, cfg.frameCount - 1 do
    local frameCharBytes = decodeMember(archive, cfg.firstFrameMember + frame, "frame " .. frame .. " char")
    local framePalBytes = decodeMember(archive, cfg.firstPaletteMember + frame, "frame " .. frame .. " palette")
    local frameChar, charErr = G2dDecoder.decodeChar(frameCharBytes, { label = "frame " .. frame .. " char" })
    local framePal, palErr = G2dDecoder.decodePalette(framePalBytes, { label = "frame " .. frame .. " palette" })
    frameChar = must(frameChar, charErr)
    framePal = must(framePal, palErr)
    if math.floor(#frameChar.tiles / (frameChar.depth == 3 and 32 or 64)) ~= tilesPerFrame then
      Errors.raise("FIELD_UI_SOURCE_INVALID", "frame " .. frame .. " has a different tile count", {
        frame = frame,
        tiles = math.floor(#frameChar.tiles / (frameChar.depth == 3 and 32 or 64)),
      })
    end
    for tile = 0, tilesPerFrame - 1 do
      blitTile(rgba, atlasWidth, tile * 8, frame * 8, frameChar, tile, 0, framePal.colors)
    end
    frameTiles[frame] = { x = 0, y = frame * 8, width = atlasWidth, height = 8 }
    palettes[frame] = { colors = framePal.colors }
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":member:" .. (cfg.firstFrameMember + frame),
      sha1 = sha1hex(frameCharBytes),
    }
    deps[#deps + 1] = {
      name = manifestConfig.dialogueFrames.alias .. ":palette:" .. (cfg.firstPaletteMember + frame),
      sha1 = sha1hex(framePalBytes),
    }
  end
  assets[tilesPath] = PngWriter.encode(atlasWidth, atlasHeight, concatChars(rgba))
  manifestAssets["hgss.dialogue_frame.tiles"] = { image = tilesPath, width = atlasWidth, height = atlasHeight }
  deps[#deps + 1] = { name = manifestConfig.dialogueFrames.alias .. ":narc", sha1 = sha1hex(archiveBytes) }
  return {
    count = cfg.frameCount,
    frameTiles = frameTiles,
    palettes = palettes,
  }
end

local function compileSignposts(romFs, sha1hex, deps, assets, manifestAssets)
  local info, archive, archiveBytes = loadArchive(romFs, manifestConfig.signposts.alias)
  local cfg = manifestConfig.signposts
  local frameCharBytes = decodeMember(archive, cfg.frameMember, "signpost frame char")
  local framePalBytes = decodeMember(archive, cfg.paletteMember, "signpost frame palette")
  local frameChar, charErr = G2dDecoder.decodeChar(frameCharBytes, { label = "signpost frame char" })
  local framePal, palErr = G2dDecoder.decodePalette(framePalBytes, { label = "signpost frame palette" })
  frameChar = must(frameChar, charErr)
  framePal = must(framePal, palErr)
  local frameTiles = math.floor(#frameChar.tiles / (frameChar.depth == 3 and 32 or 64))
  local framePath = FieldUiAssetCache.assetDir() .. "/signpost-tiles.png"
  assets[framePath] = renderTiles(frameChar, framePal.colors, frameTiles, frameTiles * 8)
  manifestAssets["hgss.signpost.tiles"] = { image = framePath, width = frameTiles * 8, height = 8 }
  deps[#deps + 1] = { name = manifestConfig.signposts.alias .. ":frame", sha1 = sha1hex(archiveBytes) }

  -- Wayfinding: the selected (type, map) members stacked in a shared atlas,
  -- one row per pair. All members carry the same tile count in the real
  -- dump (24 tiles = 192 px wide).
  local wayfindingPath = FieldUiAssetCache.assetDir() .. "/wayfinding-tiles.png"
  local wayfinding = {}
  local rows = {}
  local wayfindingTypes = {}
  for sourceType in pairs(cfg.wayfinding) do
    wayfindingTypes[#wayfindingTypes + 1] = sourceType
  end
  table.sort(wayfindingTypes)
  local wayTiles
  for _, sourceType in ipairs(wayfindingTypes) do
    local spec = cfg.wayfinding[sourceType]
    for _, map in ipairs(spec.maps) do
      local member = spec.memberBase + map
      local key = sourceType .. "." .. map
      local wfBytes = decodeMember(archive, member, "wayfinding " .. key)
      local wfChar, wfErr = G2dDecoder.decodeChar(wfBytes, { label = "wayfinding " .. key })
      wfChar = must(wfChar, wfErr)
      local tiles = math.floor(#wfChar.tiles / (wfChar.depth == 3 and 32 or 64))
      if not wayTiles then
        wayTiles = tiles
      elseif tiles ~= wayTiles then
        Errors.raise(
          "FIELD_UI_SOURCE_INVALID",
          "wayfinding member " .. member .. " has " .. tiles .. " tiles, expected " .. wayTiles,
          {
            member = member,
            tiles = tiles,
          }
        )
      end
      rows[#rows + 1] = { key = key, member = member, bytes = wfBytes, char = wfChar }
    end
  end
  local rowWidth = wayTiles * 8
  local atlasHeight = #rows * 8
  local rgba = newRgba(rowWidth, atlasHeight)
  for index, row in ipairs(rows) do
    local wfChar = row.char
    for tile = 0, wayTiles - 1 do
      blitTile(rgba, rowWidth, tile * 8, (index - 1) * 8, wfChar, tile, 0, framePal.colors)
    end
    wayfinding[row.key] = { x = 0, y = (index - 1) * 8, width = rowWidth, height = 8 }
    deps[#deps + 1] = {
      name = manifestConfig.signposts.alias .. ":wayfinding:" .. row.key,
      sha1 = sha1hex(row.bytes),
    }
  end
  assets[wayfindingPath] = PngWriter.encode(rowWidth, atlasHeight, concatChars(rgba))
  manifestAssets["hgss.signpost.wayfinding"] = { image = wayfindingPath, width = rowWidth, height = atlasHeight }

  local types = {}
  for _, sourceType in ipairs(cfg.sourceTypes) do
    local typeEntry = { sourceType = sourceType }
    local spec = cfg.wayfinding[sourceType]
    if spec then
      local mapRects = {}
      for _, map in ipairs(spec.maps) do
        mapRects[map] = wayfinding[sourceType .. "." .. map]
      end
      typeEntry.wayfinding = mapRects
    end
    types[sourceType] = typeEntry
  end
  return {
    frame = { tiles = { x = 0, y = 0, width = frameTiles * 8, height = 8 } },
    types = types,
  }
end

local function compileTrainerCard(romFs, sha1hex, deps, assets, manifestAssets)
  local info, archive, archiveBytes = loadArchive(romFs, manifestConfig.trainerCard.alias)
  local cfg = manifestConfig.trainerCard
  local charBytes = decodeMember(archive, cfg.frontCharMember, "card char")
  local charData, charErr = G2dDecoder.decodeChar(charBytes, { label = "card char" })
  charData = must(charData, charErr)
  local screenBytes = decodeMember(archive, cfg.frontScreenMember, "card screen")
  local screen, screenErr = G2dDecoder.decodeScreen(screenBytes, { label = "card screen" })
  screen = must(screen, screenErr)
  local palBytes = decodeMember(archive, cfg.frontPaletteMember, "card palette")
  local pal, palErr = G2dDecoder.decodePalette(palBytes, { label = "card palette" })
  pal = must(pal, palErr)
  local path = FieldUiAssetCache.assetDir() .. "/trainer-card.png"
  assets[path] = renderScreen(charData, pal.colors, screen)
  manifestAssets["hgss.trainer_card.front"] = { image = path, width = screen.width, height = screen.height }
  deps[#deps + 1] = { name = manifestConfig.trainerCard.alias .. ":narc", sha1 = sha1hex(archiveBytes) }
  return {
    front = { x = 0, y = 0, width = screen.width, height = screen.height },
  }
end

local function compileAll(romFs, sha1hex, hashLua)
  local assets = {}
  local manifestAssets = {}
  local deps = {
    { name = "assetContract", sha1 = FieldUiAssetCache.FORMAT .. ":" .. FieldUiAssetCache.SCHEMA },
  }
  local startMenu = compileStartMenu(romFs, sha1hex, deps, assets, manifestAssets)
  local dialogueFrames = compileDialogueFrames(romFs, sha1hex, deps, assets, manifestAssets)
  local signposts = compileSignposts(romFs, sha1hex, deps, assets, manifestAssets)
  local trainerCard = compileTrainerCard(romFs, sha1hex, deps, assets, manifestAssets)

  local manifest = {
    schema = FieldUiAssetCache.SCHEMA,
    reference = { width = 256, height = 192 },
    assets = manifestAssets,
    dialogueFrames = dialogueFrames,
    signposts = signposts,
    startMenu = startMenu,
    trainerCard = trainerCard,
  }
  local ok, err = FieldUiAssetCache.validateManifest(manifest)
  if not ok then
    error(err, 0)
  end
  local marker = FieldUiAssetCache.marker(romFs:metadata().sha1, hashLua(deps))
  return {
    marker = marker,
    manifest = manifest,
    assets = assets,
    dependencies = deps,
  }
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: any): string|nil
---@return table|nil bundle
---@return Errors.Error?
function FieldUiCompiler.compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = xpcall(compileAll, function(e)
    if Errors.is(e) then
      return e
    end
    return { raw = e, trace = debug.traceback("", 2) }
  end, romFs, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  if type(result) == "table" and result.trace then
    error(result.raw, 0)
  end
  error(result, 0)
end

return FieldUiCompiler
