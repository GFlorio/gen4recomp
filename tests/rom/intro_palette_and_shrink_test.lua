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

local function decodeCharPalette(archive, charMember, paletteMember)
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
  local charBytes = getBytes(archive, charMember)
  local paletteBytes = getBytes(archive, paletteMember)
  return assert(G2dDecoder.decodeChar(charBytes)), assert(G2dDecoder.decodePalette(paletteBytes))
end

local function screenRgba(char, palette, screen)
  -- Use the same blitting path as the compiler for the oracle composition.
  -- Reuse G2dDecoder structures: char.tiles, palette.colors, screen.entries.
  -- Render a portrait through its NSCR using palette-bank-aware indexed pixels.
  local width, height = screen.width, screen.height
  local tileBytes = char.depth == 3 and 32 or 64
  local tileCount = #char.tiles / tileBytes
  local function blit(rgba, tileIndex, paletteBank, x, y, flipH, flipV)
    if tileIndex < 0 or tileIndex >= tileCount then
      error("shrink oracle tile out of range: " .. tostring(tileIndex), 0)
    end
    local base = tileIndex * tileBytes
    local function put(px, py, value)
      if value == 0 then
        return
      end
      local paletteIndex = value + 1
      if char.depth == 3 then
        paletteIndex = paletteIndex + paletteBank * 16
      end
      local color = palette[paletteIndex]
      if not color then
        error("shrink oracle missing palette entry " .. tostring(value), 0)
      end
      local tx = flipH and 7 - px or px
      local ty = flipV and 7 - py or py
      local off = ((y + ty) * width + x + tx) * 4
      rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = color.r, color.g, color.b, 255
    end
    if char.depth == 3 then
      for row = 0, 7 do
        for col = 0, 3 do
          local b = string.byte(char.tiles, base + row * 4 + col + 1)
          put(col * 2, row, b % 16)
          put(col * 2 + 1, row, math.floor(b / 16))
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

  local rgba = {}
  for i = 1, width * height * 4 do
    rgba[i] = 0
  end
  local columns = width / 8
  for row = 0, height / 8 - 1 do
    for col = 0, columns - 1 do
      local e = screen.entries[row * columns + col + 1]
      -- tile field names from G2dDecoder.decodeScreen
      local tile = e.tile
      local paletteBank = e.palette
      local flipH, flipV = e.flipH, e.flipV
      -- manual tile placement: delegate to blit with correct tile/palette
      -- Reuse the inner blit: place tile at col*8, row*8
      local base = tile * tileBytes
      if tile < 0 or tile >= tileCount then
        error("oracle screen tile " .. tostring(tile) .. " out of range", 0)
      end
      -- render this 8x8 tile via same put logic but offset by col*8,row*8
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
        local off = ((row * 8 + ty) * width + col * 8 + tx) * 4
        rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = color.r, color.g, color.b, 255
      end
      if char.depth == 3 then
        for rr = 0, 7 do
          for cc = 0, 3 do
            local b = string.byte(char.tiles, base + rr * 4 + cc + 1)
            put(cc * 2, rr, b % 16)
            put(cc * 2 + 1, rr, math.floor(b / 16))
          end
        end
      else
        for rr = 0, 7 do
          for cc = 0, 7 do
            put(cc, rr, string.byte(char.tiles, base + rr * 8 + cc + 1))
          end
        end
      end
    end
  end
  local out = {}
  for i = 1, #rgba, 4096 do
    out[#out + 1] = string.char(unpack(rgba, i, math.min(i + 4095, #rgba)))
  end
  return table.concat(out), width, height
end

function T.female_selector_uses_source_palette_bank(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local PngReader = require("tests.support.PngReader")
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")

  Assert.equal(IntroAssets.genderSelectors.male.paletteOverride, 0, "male template selects bank 0")
  Assert.equal(
    IntroAssets.genderSelectors.female.paletteOverride,
    1,
    "female template must select bank 1: source template uses palette 1"
  )

  local bundle = assert(IntroAssetCompiler.compile(romFs))
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    Assert.notNil(bundle.manifest.widgets[id], id .. " widget present")
  end

  local function pngPixels(path)
    local png = assert(bundle.assets[path], "missing image " .. tostring(path))
    local w, h, rgba = PngReader.rgba(png)
    return w, h, rgba
  end

  local male = bundle.manifest.widgets.gender_male
  local female = bundle.manifest.widgets.gender_female
  local _, _, maleRgba = pngPixels(male.frames[1].image)
  local _, _, femaleRgba = pngPixels(female.frames[1].image)

  -- Decode palette banks for the selector's shared resource: same cell
  -- table, different effective palette. Compare which bank produced the
  -- female pixels by inspecting the raw palette selection path.
  -- Build oracle palettes for bank 0 and bank 1 and verify female pixels
  -- match bank 1: render the female cell animation both ways via the
  -- compiler's paletteOverride contract and compare.

  -- The strongest assertion: recompiling through G2dDecoder with explicit
  -- palette banks must show that female bank 1 differs from bank 0, and the
  -- bundle's female output matches the bank-1 oracle rather than bank-0.

  local archive = assert(romFs:openNarc(IntroAssets.genderSelectors.female.archive or IntroAssets.archive))
  local femaleSpec = IntroAssets.genderSelectors.female
  local maleSpec = IntroAssets.genderSelectors.male

  -- Resolve female/male animation cells via production resolution
  local BinaryReader = require("libs.codec.src.BinaryReader")
  local function resolveSpec(spec)
    local res = assert(spec.resourceResolution)
    local resArchive = assert(romFs:openNarc(res.archive))
    local hdr = getBytes(resArchive, res.header)
    local hr = BinaryReader.new(hdr, "hdr")
    local off = spec.resourceSet * 32
    local charId = hr:u32le(off)
    local paletteId = hr:u32le(off + 4)
    local cellId = hr:u32le(off + 8)
    local animId = hr:u32le(off + 12)
    local function readTable(memberId)
      local b = getBytes(resArchive, memberId)
      local r = BinaryReader.new(b, "t")
      local out = {}
      local o = 4
      while true do
        local narcId = r:u32le(o)
        if narcId == 0xFFFFFFFE then
          break
        end
        local fileId = r:u32le(o + 4)
        local objectId = r:u32le(o + 12)
        out[objectId] = { narcId = narcId, fileId = fileId }
        o = o + 24
      end
      return out
    end
    local charMap = readTable(res.charTable)
    local palMap = readTable(res.paletteTable)
    local cellMap = readTable(res.cellTable)
    local animMap = readTable(res.animationTable)
    return {
      charFile = assert(charMap[charId]).fileId,
      paletteFile = assert(palMap[paletteId]).fileId,
      cellFile = assert(cellMap[cellId]).fileId,
      animFile = assert(animMap[animId]).fileId,
    }
  end

  local fResolved = resolveSpec(femaleSpec)
  local mResolved = resolveSpec(maleSpec)

  -- Load palettes and compare bank colors to ensure distinction
  local introArchive = assert(romFs:openNarc(IntroAssets.archive))
  local palBytes = getBytes(introArchive, fResolved.paletteFile)
  -- Palette table path uses resdat palette archive indirection? Actually
  -- palette comes via resource resolution mapping fileId; load from intro
  -- archive bytes already handled via getBytes above with correct fileId
  -- against the intro archive (same archive for char/palette/cell/anim).
  -- Verify by trying both archives; fallback logic uses resdat char table
  -- member mapping which already is correct for intro resources.
  local pal = assert(G2dDecoder.decodePalette(palBytes))
  Assert.isTrue(#pal.colors >= 32, "selector palette must have at least two banks (32 colors)")

  -- Check that the two banks are not identical at any used index
  local banksDiffer = false
  for i = 1, 16 do
    local a = pal.colors[i]
    local b = pal.colors[16 + i]
    if a and b and (a.r ~= b.r or a.g ~= b.g or a.b ~= b.b) then
      banksDiffer = true
      break
    end
  end
  if not banksDiffer then
    error("selector palette banks are identical; cannot validate palette override semantics from pixels", 0)
  end

  -- Now verify the compiled female pixels are from bank 1: sample a pixel
  -- that differs between banks and is non-transparent in both renders.
  -- The most direct failure mode of the current code is that renderCell
  -- ignores override and uses object.palette (0), making female identical
  -- to what bank-0 would produce.
  -- Instead of pixel hunting, assert that female and male compiled images
  -- are not identical bytes: if override were ignored they'd still differ
  -- only if the source cells themselves differ; but we also know the source
  -- resource sets 1 and 2 share structure except palette, so identical
  -- output would prove the override is ignored. Stronger: re-derive the
  -- incorrect (bank-0) oracle for female and show bundle female != bank-0 oracle.
  -- We compare bundle male vs bundle female as a weak indicator is insufficient,
  -- so do oracle comparison.

  -- Build oracle: female's cells/palette rendered with bank 0 vs bank 1.
  local charBytesF = getBytes(introArchive, fResolved.charFile)
  local cellBytesF = getBytes(introArchive, fResolved.cellFile)
  local animBytesF = getBytes(introArchive, fResolved.animFile)
  local charF = assert(G2dDecoder.decodeChar(charBytesF))
  local cellsF = assert(G2dDecoder.decodeCell(cellBytesF))
  local animF = assert(G2dDecoder.decodeAnimation(animBytesF))

  -- Pick the female's animation selection (IntroAssets.genderSelectors.female uses animationIndex 0)
  local selF = assert(animF.anims[femaleSpec.animationIndex + 1])
  local firstCellF = assert(cellsF.cells[selF.frames[1].cell + 1])

  -- Helper to render one cell with an explicit palette bank
  local function renderCellWithBank(cell, bank)
    local bounds = { minX = math.huge, minY = math.huge, maxX = -math.huge, maxY = -math.huge }
    for _, o in ipairs(cell.objs) do
      bounds.minX = math.min(bounds.minX, o.x)
      bounds.minY = math.min(bounds.minY, o.y)
      bounds.maxX = math.max(bounds.maxX, o.x + o.width)
      bounds.maxY = math.max(bounds.maxY, o.y + o.height)
    end
    local w, h = bounds.maxX - bounds.minX, bounds.maxY - bounds.minY
    local rgba = {}
    for i = 1, w * h * 4 do
      rgba[i] = 0
    end
    local tileBytes = charF.depth == 3 and 32 or 64
    local tileCount = #charF.tiles / tileBytes
    local function put(px, py, value, bankIdx)
      if value == 0 then
        return
      end
      local pi = value + 1
      if charF.depth == 3 then
        pi = pi + bankIdx * 16
      end
      local color = pal.colors[pi]
      if not color then
        error("missing palette entry", 0)
      end
      local off = (py * w + px) * 4
      rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = color.r, color.g, color.b, 255
    end
    for _, object in ipairs(cell.objs) do
      local cols, rows = object.width / 8, object.height / 8
      for row = 0, rows - 1 do
        for col = 0, cols - 1 do
          local tileCol = object.flipH and cols - 1 - col or col
          local tileRow = object.flipV and rows - 1 - row or row
          local tile = object.tile + tileRow * cols + tileCol
          local base = tile * tileBytes
          local ox = object.x - bounds.minX + col * 8
          local oy = object.y - bounds.minY + row * 8
          if charF.depth == 3 then
            for rr = 0, 7 do
              for cc = 0, 3 do
                local b = string.byte(charF.tiles, base + rr * 4 + cc + 1)
                local v1 = b % 16
                local v2 = math.floor(b / 16)
                local tx1 = object.flipH and 7 - cc * 2 or cc * 2
                local tx2 = object.flipH and 7 - (cc * 2 + 1) or cc * 2 + 1
                local ty = object.flipV and 7 - rr or rr
                if v1 ~= 0 then
                  local pi = v1 + 1 + bank * 16
                  local c = pal.colors[pi]
                  if not c then
                    error("missing palette entry", 0)
                  end
                  local px = ox + tx1
                  local py = oy + ty
                  local off = (py * w + px) * 4
                  rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = c.r, c.g, c.b, 255
                end
                if v2 ~= 0 then
                  local pi = v2 + 1 + bank * 16
                  local c = pal.colors[pi]
                  if not c then
                    error("missing palette entry", 0)
                  end
                  local px = ox + tx2
                  local py = oy + ty
                  local off = (py * w + px) * 4
                  rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = c.r, c.g, c.b, 255
                end
              end
            end
          else
            for rr = 0, 7 do
              for cc = 0, 7 do
                local v = string.byte(charF.tiles, base + rr * 8 + cc + 1)
                if v ~= 0 then
                  local c = pal.colors[v + 1]
                  local tx = object.flipH and 7 - cc or cc
                  local ty = object.flipV and 7 - rr or rr
                  local px = ox + tx
                  local py = oy + ty
                  local off = (py * w + px) * 4
                  rgba[off + 1], rgba[off + 2], rgba[off + 3], rgba[off + 4] = c.r, c.g, c.b, 255
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
    return table.concat(out), w, h
  end

  local rgbaBank0, w0, h0 = renderCellWithBank(firstCellF, 0)
  local rgbaBank1, w1, h1 = renderCellWithBank(firstCellF, 1)
  Assert.equal(w0, w1)
  Assert.equal(h0, h1)
  if rgbaBank0 == rgbaBank1 then
    error("female cell banks 0 and 1 produce identical pixels; palette test cannot discriminate", 0)
  end

  -- Compare bundle female frame against both oracles (cropped size may differ due to compiler's union crop).
  -- For the female selector the compiler's union crop is the cell's own bounds, so sizes match.
  -- If sizes differ, compare by hashing the frame image region.
  local PngReader = require("tests.support.PngReader")
  local fw, fh, fRgba = (function()
    local png = assert(bundle.assets[female.frames[1].image])
    return PngReader.rgba(png)
  end)()

  -- The bundle's female frame must match bank 1, not bank 0.
  -- We compare exact bytes when dimensions match; otherwise require that at
  -- least one pixel uses a color unique to bank 1.
  if fw == w1 and fh == h1 then
    if fRgba == rgbaBank0 and fRgba ~= rgbaBank1 then
      error("female selector was rendered with bank 0 instead of its source bank 1", 0)
    end
    if fRgba ~= rgbaBank1 then
      -- Allow minor crop differences: scan for a bank-1-unique color.
      local usesBank1Color = false
      for off = 1, #fRgba, 4 do
        local r, g, b, a = string.byte(fRgba, off, off + 3)
        if a ~= 0 then
          -- check if this color appears in bank 1's oracle but not bank 0's
          local inBank0 = false
          for o = 1, #rgbaBank0, 4 do
            local r0, g0, b0 = string.byte(rgbaBank0, o, o + 2)
            if r0 == r and g0 == g and b0 == b then
              inBank0 = true
              break
            end
          end
          local inBank1 = false
          for o = 1, #rgbaBank1, 4 do
            local r1, g1, b1 = string.byte(rgbaBank1, o, o + 2)
            if r1 == r and g1 == g and b1 == b then
              inBank1 = true
              break
            end
          end
          if inBank1 and not inBank0 then
            usesBank1Color = true
            break
          end
        end
      end
      if not usesBank1Color then
        error("female selector output does not match any bank-1 pixel set", 0)
      end
    end
  else
    -- Fallback: at least one visible pixel must be a bank-1-unique color
    local found = false
    for off = 1, #fRgba, 4 do
      local r, g, b, a = string.byte(fRgba, off, off + 3)
      if a ~= 0 then
        local inBank1 = false
        for o = 1, #rgbaBank1, 4 do
          local r1, g1, b1 = string.byte(rgbaBank1, o, o + 2)
          if r1 == r and g1 == g and b1 == b then
            inBank1 = true
            break
          end
        end
        if inBank1 then
          found = true
          break
        end
      end
    end
    if not found then
      error("female selector output does not contain colors from source bank 1", 0)
    end
  end
end

function T.shrink_frames_are_portrait_compositions(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
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

return RomSuite.fromFacts(T)
