-- Captures two production pipeline assertions:
--  - the female selector uses the palette bank selected by its source template
--  - shrink frames are portrait-screen compositions in the source-visible order

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function getBytes(archive, memberId)
  local Lz10 = require("romdump.src.digest.Lz10")
  local bytes = assert(archive:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes))
  end
  return bytes
end

local function readPaletteRecords(romFs, resolution)
  local archive = assert(romFs:openNarc(resolution.archive))
  local bytes = getBytes(archive, resolution.paletteTable)
  local BinaryReader = require("libs.codec.src.BinaryReader")
  local reader = BinaryReader.new(bytes, "intro palette table")
  local records = {}
  local offset = 4
  while true do
    local narcId = reader:u32le(offset)
    if narcId == 0xFFFFFFFE then
      return records
    end
    local record = {
      narcId = narcId,
      fileId = reader:u32le(offset + 4),
      compressed = reader:u32le(offset + 8),
      objectId = reader:u32le(offset + 12),
      vram = reader:u32le(offset + 16),
      bankCount = reader:u32le(offset + 20),
    }
    records[#records + 1] = record
    offset = offset + 24
  end
end

-- Independent oracle for ObjPlttTransfer's sequential MAIN/SUB allocation.
local function buildPaletteLayout(records)
  local layout = { main = {}, sub = {} }
  local cursor = { main = 0, sub = 0 }
  for _, record in ipairs(records) do
    local targets = {}
    if record.vram == 1 or record.vram == 3 then
      targets[#targets + 1] = "main"
    end
    if record.vram == 2 or record.vram == 3 then
      targets[#targets + 1] = "sub"
    end
    for _, target in ipairs(targets) do
      for localBank = 0, record.bankCount - 1 do
        layout[target][cursor[target]] = { record = record, localBank = localBank }
        cursor[target] = cursor[target] + 1
      end
    end
  end
  return layout
end

local function sourceOwner(layout, vram, paletteNumber)
  local target = assert(({ main = "main", sub = "sub" })[vram])
  return layout[target][paletteNumber]
end

local function decodeSelectorResource(romFs, IntroAssets, spec)
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
  local BinaryReader = require("libs.codec.src.BinaryReader")
  local res = assert(spec.resourceResolution)
  local resArchive = assert(romFs:openNarc(res.archive))
  local hdr = getBytes(resArchive, res.header)
  local hr = BinaryReader.new(hdr, "hdr")
  local off = spec.resourceSet * 32
  local charId, paletteId, cellId, animId = hr:u32le(off), hr:u32le(off + 4), hr:u32le(off + 8), hr:u32le(off + 12)
  local function readTable(memberId)
    local b = getBytes(resArchive, memberId)
    local r = BinaryReader.new(b, "t")
    local out, o = {}, 4
    while true do
      local narcId = r:u32le(o)
      if narcId == 0xFFFFFFFE then
        break
      end
      out[r:u32le(o + 12)] = { fileId = r:u32le(o + 4) }
      o = o + 24
    end
    return out
  end
  local charFile = assert(readTable(res.charTable)[charId]).fileId
  local paletteFile = assert(readTable(res.paletteTable)[paletteId]).fileId
  local cellFile = assert(readTable(res.cellTable)[cellId]).fileId
  local animFile = assert(readTable(res.animationTable)[animId]).fileId

  local archive = assert(romFs:openNarc(spec.archive or IntroAssets.archive))
  local char = assert(G2dDecoder.decodeChar(getBytes(archive, charFile)))
  local palette = assert(G2dDecoder.decodePalette(getBytes(archive, paletteFile)))
  local cells = assert(G2dDecoder.decodeCell(getBytes(archive, cellFile)))
  local animation = assert(G2dDecoder.decodeAnimation(getBytes(archive, animFile)))
  local anim = assert(animation.anims[spec.animationIndex + 1])
  local cell = assert(cells.cells[anim.frames[1].cell + 1])
  return char, palette, cell, anim.frames
end

-- Render the exact image one bank hypothesis would produce for this cell,
-- positioned the same way IntroAssetCompiler.renderCell places objects onto
-- the widget's generated canvas (destination = object.x/y offset by anchor;
-- source tile selection and per-pixel placement mirror its flip handling).
local function renderCellOracle(char, palette, cell, width, height, anchorX, anchorY, bankFor)
  -- The compiler passes a resolved 16-color view; source comparisons pass a
  -- decoded palette record. Keep the oracle independent of that producer
  -- representation while retaining the explicit local-bank selection.
  local colors = palette.colors or palette
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  for _, object in ipairs(cell.objs) do
    local bank = bankFor(object)
    local cols, rows = object.width / 8, object.height / 8
    for row = 0, rows - 1 do
      for col = 0, cols - 1 do
        local tileCol = object.flipH and cols - 1 - col or col
        local tileRow = object.flipV and rows - 1 - row or row
        local tile = object.tile + tileRow * cols + tileCol
        if tile < 0 or tile >= tileCount then
          error("intro selector oracle tile reference exceeds source char data: " .. tostring(tile), 0)
        end
        local base = tile * tileBytes
        local destX = object.x + anchorX + col * 8
        local destY = object.y + anchorY + row * 8
        for rr = 0, 7 do
          for cc = 0, 3 do
            local b = string.byte(char.tiles, base + rr * 4 + cc + 1 --[[@as integer]])
            local values = { b % 16, math.floor(b / 16) }
            for pairOffset, value in ipairs(values) do
              if value ~= 0 then
                local color = colors[value + 1 + bank * 16]
                if color then
                  local localX = cc * 2 + (pairOffset - 1)
                  local targetX = object.flipH and 7 - localX or localX
                  local targetY = object.flipV and 7 - rr or rr
                  local dx, dy = destX + targetX, destY + targetY
                  if dx >= 0 and dx < width and dy >= 0 and dy < height then
                    local off = (dy * width + dx) * 4
                    rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = color.r, color.g, color.b, 255
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  local out = {}
  for i = 1, #rgba, 4096 do
    out[#out + 1] = string.char(unpack(rgba, i, math.min(i + 4095, #rgba)))
  end
  return table.concat(out)
end

local function renderAnimatedCellOracle(char, palette, cell, frame, width, height, anchorX, anchorY, bankFor)
  local tx = frame.translateX or 0
  local ty = frame.translateY or 0
  local sx = frame.scaleX or 1
  local sy = frame.scaleY or 1
  local rotation = frame.rotation or 0
  if tx == 0 and ty == 0 and sx == 1 and sy == 1 and rotation == 0 then
    return renderCellOracle(char, palette, cell, width, height, anchorX, anchorY, bankFor)
  end
  if rotation ~= 0 then
    error("intro palette oracle does not support rotated source frames", 0)
  end

  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge
  for _, object in ipairs(cell.objs) do
    minX = math.min(minX, object.x)
    minY = math.min(minY, object.y)
    maxX = math.max(maxX, object.x + object.width)
    maxY = math.max(maxY, object.y + object.height)
  end
  local cellWidth, cellHeight = maxX - minX, maxY - minY
  local cellRgba = renderCellOracle(char, palette, cell, cellWidth, cellHeight, -minX, -minY, bankFor)
  local output = {}
  for index = 1, width * height * 4 do
    output[index] = 0
  end
  for dy = 0, height - 1 do
    for dx = 0, width - 1 do
      local worldX = -anchorX + dx
      local worldY = -anchorY + dy
      local sourceX = math.floor((worldX - tx) / sx - minX + 0.5)
      local sourceY = math.floor((worldY - ty) / sy - minY + 0.5)
      if sourceX >= 0 and sourceX < cellWidth and sourceY >= 0 and sourceY < cellHeight then
        local sourceOffset = (sourceY * cellWidth + sourceX) * 4
        local alpha = string.byte(cellRgba, (sourceOffset + 4) --[[@as integer]])
        if alpha ~= 0 then
          local outputOffset = (dy * width + dx) * 4
          output[outputOffset + 1] = string.byte(cellRgba, (sourceOffset + 1) --[[@as integer]])
          output[outputOffset + 2] = string.byte(cellRgba, (sourceOffset + 2) --[[@as integer]])
          output[outputOffset + 3] = string.byte(cellRgba, (sourceOffset + 3) --[[@as integer]])
          output[outputOffset + 4] = alpha
        end
      end
    end
  end
  local out = {}
  for index = 1, #output, 4096 do
    out[#out + 1] = string.char(unpack(output, index, math.min(index + 4095, #output)))
  end
  return table.concat(out)
end

function T.source_palette_table_allocates_the_pinned_oak_absolute_banks(romFs)
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local resolution = assert(IntroAssets.genderSelectors.male.resourceResolution)
  local layout = buildPaletteLayout(readPaletteRecords(romFs, resolution))
  for _, expected in ipairs({
    { vram = "sub", paletteNumber = 0, objectId = 2, localBank = 0, label = "male selector" },
    { vram = "sub", paletteNumber = 1, objectId = 3, localBank = 0, label = "female selector" },
    { vram = "main", paletteNumber = 4, objectId = 7, localBank = 0, label = "Marill" },
    { vram = "main", paletteNumber = 5, objectId = 7, localBank = 1, label = "ball opening" },
  }) do
    local slot = sourceOwner(layout, expected.vram, expected.paletteNumber)
    Assert.notNil(slot, expected.label .. " has an allocated absolute palette bank")
    Assert.equal(slot.record.objectId, expected.objectId, expected.label .. " owner resource")
    Assert.equal(slot.localBank, expected.localBank, expected.label .. " owner local bank")
  end
end

function T.generated_fourbpp_pixels_follow_absolute_palette_owners(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local PngReader = require("tests.support.PngReader")

  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local resolution = assert(IntroAssets.genderSelectors.male.resourceResolution)
  local layout = buildPaletteLayout(readPaletteRecords(romFs, resolution))
  local introArchive = assert(romFs:openNarc(IntroAssets.archive))
  local discriminatedAny = false

  for _, gender in ipairs({ "male", "female" }) do
    local spec = IntroAssets.genderSelectors[gender]
    local widget = assert(bundle.manifest.widgets["gender_" .. gender], gender .. " selector widget present")
    local _, _, bundleRgba = PngReader.rgba(assert(bundle.assets[widget.frames[1].image]))

    local char, palette, cell = decodeSelectorResource(romFs, IntroAssets, spec)
    Assert.isTrue(#cell.objs > 0, gender .. " selector cell has OAM objects")
    local slot = assert(sourceOwner(layout, spec.vram, spec.paletteNumber), gender .. " absolute palette owner")
    Assert.equal(slot.record.narcId, spec.resourceResolution.sourceNarcId, gender .. " owner archive")
    local ownerPalette =
      assert(require("romdump.src.digest.G2dDecoder").decodePalette(getBytes(introArchive, slot.record.fileId)))

    local sourceRgba = renderCellOracle(
      char,
      palette,
      cell,
      widget.width,
      widget.height,
      widget.anchor.x,
      widget.anchor.y,
      function(object)
        return object.palette
      end
    )
    local absoluteRgba = renderCellOracle(
      char,
      ownerPalette,
      cell,
      widget.width,
      widget.height,
      widget.anchor.x,
      widget.anchor.y,
      function()
        return slot.localBank
      end
    )

    Assert.equal(bundleRgba, absoluteRgba, gender .. " selector pixels match the absolute-bank oracle")
    if sourceRgba ~= absoluteRgba then
      discriminatedAny = true
    end
  end

  Assert.isTrue(
    discriminatedAny,
    "at least one selector must distinguish absolute-bank ownership from object-local palette selection"
  )
end

function T.shrink_frames_are_portrait_compositions(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local PngReader = require("tests.support.PngReader")
  local IntroAssetImage = require("romdump.src.digest.IntroAssetImage")

  local bundle = assert(IntroAssetCompiler.compile(romFs))

  for _, gender in ipairs({ "male", "female" }) do
    local id = "shrink_" .. gender
    local widget = assert(bundle.manifest.widgets[id], id .. " present")
    local spec = IntroAssets.shrink[gender]
    local expectedOrder = spec.chars
    Assert.equal(#widget.frames, #expectedOrder, id .. " frame count matches replacement order")
    -- Each frame image must be portrait-composed, not a generic tile sheet.
    -- A tile sheet would be 128px wide (16 tiles) with height a multiple of 8;
    -- a portrait screen is not that shape after crop.
    Assert.isTrue(widget.width > 16 and widget.height > 16, id .. " frames are portrait-sized")
    -- Provenance must identify the portrait screen dependency.
    -- Before the correction shrink provenance is a single rule with no screen.
    local prov = widget.provenance or {}
    if prov.screenMember == nil and prov.screen == nil and prov.portraitScreen == nil then
      -- Also check manifest-level provenance: the widget must name the screen
      -- member. A generic rule alone is insufficient.
      local hasScreenField = false
      for k in pairs(prov) do
        if k:find("screen") then
          hasScreenField = true
        end
      end
      if not hasScreenField then
        error(id .. " provenance does not identify the portrait screen used for shrink composition", 0)
      end
    end
  end

  -- Pixel oracle: build the expected screen-composed portraits and compare
  -- against the bundle via the same union-crop path. Before the correction
  -- each frame is a raw 16-column sheet, so the oracle will not match.

  local function buildScreenOracle(gender)
    local spec = IntroAssets.shrink[gender]
    local archive = assert(romFs:openNarc(IntroAssets.archive))
    local G2dDecoder2 = require("romdump.src.digest.G2dDecoder")
    -- Replicate IntroAssetCompiler.renderScreen exactly, including blitTile semantics.
    local function newRgba(w, h)
      local a = {}
      for i = 1, w * h * 4 do
        a[i] = 0
      end
      return a
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
        error("oracle tile out of range " .. tostring(tileIndex), 0)
      end
      local function put(px, py, value)
        if value == 0 then
          return
        end
        local pi = value + 1
        if char.depth == 3 then
          pi = pi + paletteBank * 16
        end
        local color = palette[pi]
        if not color then
          error("oracle missing palette entry", 0)
        end
        local tx = flipH and 7 - px or px
        local ty = flipV and 7 - py or py
        local off = ((y + ty) * width + x + tx) * 4
        rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = color.r, color.g, color.b, 255
      end
      local base = tileIndex * tileBytes
      if char.depth == 3 then
        for row = 0, 7 do
          for col = 0, 3 do
            local v = string.byte(char.tiles, base + row * 4 + col + 1)
            put(col * 2, row, v % 16)
            put(col * 2 + 1, row, math.floor(v / 16))
          end
        end
      else
        for row = 0, 7 do
          for col = 0, 7 do
            put(col, row, string.byte(char.tiles, base + row * 8 + col + 1))
          end
        end
      end
    end
    local function renderScreenViaOracle(char, palette, screen)
      local rgba = newRgba(screen.width, screen.height)
      local cols = screen.width / 8
      for row = 0, screen.height / 8 - 1 do
        for col = 0, cols - 1 do
          local e = screen.entries[row * cols + col + 1]
          blitTile(rgba, screen.width, char, col * 8, row * 8, e.tile, palette, e.palette, e.flipH, e.flipV)
        end
      end
      return { width = screen.width, height = screen.height, rgba = concatBytes(rgba) }
    end

    local screenBytes = getBytes(archive, 9)
    local screen = assert(G2dDecoder2.decodeScreen(screenBytes))
    local images = {}
    local width = nil
    for _, charMember in ipairs(spec.chars) do
      local charB = getBytes(archive, charMember)
      local palB = getBytes(archive, spec.palette)
      local char = assert(G2dDecoder2.decodeChar(charB))
      local pal = assert(G2dDecoder2.decodePalette(palB))
      local img = renderScreenViaOracle(char, pal.colors, screen)
      if width == nil then
        width = img.width
      else
        Assert.equal(img.width, width, "oracle portrait width stable")
      end
      images[#images + 1] = img
    end
    local cropped = IntroAssetImage.cropAlphaUnion(images, { x = width / 2, y = images[1].height })
    return cropped
  end

  for _, gender in ipairs({ "male", "female" }) do
    local id = "shrink_" .. gender
    local widget = bundle.manifest.widgets[id]
    local oracle = buildScreenOracle(gender)
    -- Bundle width/height are the union-cropped portrait size; a sheet-based
    -- compiler produces a different cropped size (128-wide sheet union).
    if widget.width == 128 then
      error(id .. " exhibits 16-column tile-sheet width 128 instead of portrait composition", 0)
    end
    Assert.equal(widget.width, oracle.width, id .. " width matches portrait-composed oracle")
    Assert.equal(widget.height, oracle.height, id .. " height matches portrait-composed oracle")
    Assert.deepEqual(widget.anchor, oracle.anchor, id .. " anchor matches portrait-composed oracle")
    Assert.deepEqual(widget.sourceBounds, oracle.sourceBounds, id .. " sourceBounds matches portrait-composed oracle")

    -- First frame pixels must match the oracle's first frame exactly.
    local firstBundlePng = assert(bundle.assets[widget.frames[1].image])
    local _, _, bundleRgba = PngReader.rgba(firstBundlePng)
    local oracleRgba = oracle.frames[1].rgba
    if bundleRgba ~= oracleRgba then
      error(
        id
          .. " first frame pixels do not match the portrait-screen composition oracle for char "
          .. tostring(IntroAssets.shrink[gender].chars[1]),
        0
      )
    end
    -- All frames must be distinct (no duplication of pre-shrink full art).
    local seen = {}
    for idx, f in ipairs(widget.frames) do
      local png = assert(bundle.assets[f.image])
      if seen[png] then
        error(
          id
            .. " frame "
            .. idx
            .. " duplicates an earlier frame; replacement order may include the pre-shrink full art",
          0
        )
      end
      seen[png] = true
    end
  end

  -- Dependencies must record the portrait screen member 9 alongside each char.
  -- Current compileShrink does not depend on screen 9 at all, so a lookup
  -- for shrink-specific screen dependency would be absent.
  local seenScreenDep = false
  for _, dep in ipairs(bundle.dependencies.dependencies) do
    if dep.role and dep.role:find("shrink") and dep.memberId == 9 then
      seenScreenDep = true
    end
    if dep.role == "shrink_male:screen" or dep.role == "shrink_female:screen" then
      seenScreenDep = true
    end
  end
  -- Allow alternative provenance shape: manifest provenance lists screenMember.
  for _, gender in ipairs({ "male", "female" }) do
    local w = bundle.manifest.widgets["shrink_" .. gender]
    if
      w.provenance and (w.provenance.screenMember == 9 or w.provenance.screen == 9 or w.provenance.portraitScreen == 9)
    then
      seenScreenDep = true
    end
  end
  if not seenScreenDep then
    error("provenance missing portrait screen member 9 for shrink composition", 0)
  end
end

-- The pinned source (src/oaks_speech_obj.c, sSpriteTemplates) assigns an
-- absolute OBJ palette number and target engine to each affected template.
local sourcePaletteByAsset = {
  gender_male = { vram = "sub", paletteNumber = 0 },
  gender_female = { vram = "sub", paletteNumber = 1 },
  ball_open = { vram = "main", paletteNumber = 5 },
  marill_appear = { vram = "main", paletteNumber = 4 },
  marill = { vram = "main", paletteNumber = 4 },
}

function T.oak_speech_selectors_match_pinned_source_sprite_templates(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")

  for id, expected in pairs(sourcePaletteByAsset) do
    local config = id:find("gender_", 1, true) == 1 and IntroAssets.genderSelectors[id:gsub("gender_", "")]
      or IntroAssets[id]
    Assert.equal(config.vram, expected.vram, id .. " target engine")
    Assert.equal(config.paletteNumber, expected.paletteNumber, id .. " source palette number")
  end

  local bundle = assert(IntroAssetCompiler.compile(romFs))
  for id in pairs(sourcePaletteByAsset) do
    local widget = assert(bundle.manifest.widgets[id], id .. " widget present")
    local provenance = widget.provenance or {}
    Assert.equal(
      provenance.paletteNumber,
      sourcePaletteByAsset[id].paletteNumber,
      id .. " provenance records the source palette number"
    )
  end
end

function T.critical_widget_geometry_and_centers_survive_palette_resolution(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local widgets = bundle.manifest.widgets

  local expectedCenters = {
    ball_open = { x = 160, y = 80 },
    marill_appear = { x = 160, y = 80 },
    marill = { x = 160, y = 80 },
  }
  for id, center in pairs(expectedCenters) do
    local widget = assert(widgets[id], id .. " widget present")
    Assert.deepEqual(widget.sourceCenter, center, id .. " source center is preserved through palette resolution")
    Assert.isTrue(
      widget.sourceBounds.width > 0 and widget.sourceBounds.height > 0,
      id .. " retains finite transformed source bounds"
    )
    Assert.isTrue(#widget.frames > 0, id .. " retains at least one decoded animation frame")
  end
  Assert.deepEqual(widgets.gender_male.sourceCenter, { x = 64, y = 104 })
  Assert.deepEqual(widgets.gender_female.sourceCenter, { x = 192, y = 104 })
  Assert.deepEqual(bundle.manifest.genderSelector.buttons.male.bounds, { x = 18, y = 25, width = 93, height = 148 })
  Assert.deepEqual(
    bundle.manifest.profileConfirmation.buttons.female.no.textBounds,
    { x = 16, y = 128, width = 104, height = 24 }
  )
end

function T.ball_and_marill_pixels_use_their_distinct_absolute_palette_banks(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local PngReader = require("tests.support.PngReader")
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local resolution = assert(IntroAssets.ball_open.resourceResolution)
  local layout = buildPaletteLayout(readPaletteRecords(romFs, resolution))
  local introArchive = assert(romFs:openNarc(IntroAssets.archive))
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    local spec = assert(IntroAssets[id])
    local slot = assert(sourceOwner(layout, spec.vram, spec.paletteNumber), id .. " absolute palette owner")
    Assert.equal(slot.record.objectId, 7, id .. " uses resource id 7")
    Assert.equal(slot.localBank, id == "ball_open" and 1 or 0, id .. " local palette bank")
    local char, embeddedPalette, cell, animationFrames = decodeSelectorResource(romFs, IntroAssets, spec)
    local ownerPalette = assert(G2dDecoder.decodePalette(getBytes(introArchive, slot.record.fileId)))
    local widget = assert(bundle.manifest.widgets[id])
    local _, _, bundleRgba = PngReader.rgba(assert(bundle.assets[widget.frames[1].image]))
    local absoluteRgba = renderAnimatedCellOracle(
      char,
      ownerPalette,
      cell,
      animationFrames[1],
      widget.width,
      widget.height,
      widget.anchor.x,
      widget.anchor.y,
      function()
        return slot.localBank
      end
    )
    Assert.equal(bundleRgba, absoluteRgba, id .. " pixels match the absolute-bank oracle")
    local sourceRgba = renderAnimatedCellOracle(
      char,
      embeddedPalette,
      cell,
      animationFrames[1],
      widget.width,
      widget.height,
      widget.anchor.x,
      widget.anchor.y,
      function(object)
        return object.palette
      end
    )
    if sourceRgba ~= absoluteRgba then
      Assert.notEqual(bundleRgba, sourceRgba, id .. " pixels must follow the absolute-bank hypothesis")
    end
    -- The two hypotheses are both rendered explicitly.  A ROM may have an
    -- object-local bank equal to the resolved bank, or equal colors in both
    -- banks, so identical output is valid and must not invalidate the test.
  end
end

return RomSuite.fromFacts(T)
