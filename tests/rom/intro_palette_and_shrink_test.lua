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

function T.gender_selector_pixels_follow_oam_embedded_palette_not_the_raw_template_selector(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local PngReader = require("tests.support.PngReader")
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
  local BinaryReader = require("libs.codec.src.BinaryReader")

  Assert.equal(IntroAssets.genderSelectors.male.paletteOverride, 0, "male template selects slot 0")
  Assert.equal(IntroAssets.genderSelectors.female.paletteOverride, 1, "female template selects slot 1")

  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local female = assert(bundle.manifest.widgets.gender_female, "female selector widget present")
  local _, _, bundleRgba = PngReader.rgba(assert(bundle.assets[female.frames[1].image]))

  -- Resolve female's own resource set exactly like the production compiler,
  -- then decode its first animation cell directly. The pinned source
  -- template's raw `.pal` selector (1) names a sprite-system VRAM slot, not a
  -- bank inside this resource's own decoded palette; the real per-object
  -- color choice is the OAM cell's own decoded palette-bank field.
  local femaleSpec = IntroAssets.genderSelectors.female
  local res = assert(femaleSpec.resourceResolution)
  local resArchive = assert(romFs:openNarc(res.archive))
  local hdr = getBytes(resArchive, res.header)
  local hr = BinaryReader.new(hdr, "hdr")
  local off = femaleSpec.resourceSet * 32
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

  local archive = assert(romFs:openNarc(femaleSpec.archive or IntroAssets.archive))
  local char = assert(G2dDecoder.decodeChar(getBytes(archive, charFile)))
  local palette = assert(G2dDecoder.decodePalette(getBytes(archive, paletteFile)))
  local cells = assert(G2dDecoder.decodeCell(getBytes(archive, cellFile)))
  local animation = assert(G2dDecoder.decodeAnimation(getBytes(archive, animFile)))
  local anim = assert(animation.anims[femaleSpec.animationIndex + 1])
  local cell = assert(cells.cells[anim.frames[1].cell + 1])
  Assert.isTrue(#cell.objs > 0, "female selector cell has OAM objects")

  -- Collect the opaque colors each hypothesis would produce for this cell:
  -- one bank per object chosen either from the object's own decoded OAM
  -- field, or (the wrong hypothesis) from the raw template selector treated
  -- as a local bank index.
  local function colorsFor(bankFor)
    local colors = {}
    local tileBytes = char.depth == 3 and 32 or 64
    for _, object in ipairs(cell.objs) do
      local bank = bankFor(object)
      local cols, rows = object.width / 8, object.height / 8
      for row = 0, rows - 1 do
        for col = 0, cols - 1 do
          local tileCol = object.flipH and cols - 1 - col or col
          local tileRow = object.flipV and rows - 1 - row or row
          local tile = object.tile + tileRow * cols + tileCol
          local base = tile * tileBytes
          for rr = 0, 7 do
            for cc = 0, 3 do
              local b = string.byte(char.tiles, base + rr * 4 + cc + 1)
              for _, value in ipairs({ b % 16, math.floor(b / 16) }) do
                if value ~= 0 then
                  local color = palette.colors[value + 1 + bank * 16]
                  if color then
                    colors[string.char(color.r, color.g, color.b)] = true
                  end
                end
              end
            end
          end
        end
      end
    end
    return colors
  end

  local embeddedColors = colorsFor(function(object)
    return object.palette
  end)
  local rawSelectorColors = colorsFor(function()
    return femaleSpec.paletteOverride
  end)

  local embeddedOnly = {}
  for color in pairs(embeddedColors) do
    if not rawSelectorColors[color] then
      embeddedOnly[color] = true
    end
  end
  if next(embeddedOnly) == nil then
    error(
      "the OAM-embedded bank and the raw template-selector-as-bank hypothesis produce identical colors; "
        .. "this fixture cannot discriminate between them",
      0
    )
  end

  local sawEmbeddedOnlyColor = false
  for offset = 1, #bundleRgba, 4 do
    local r, g, b, a = string.byte(bundleRgba, offset, offset + 3)
    if a and a > 0 and embeddedOnly[string.char(r, g, b)] then
      sawEmbeddedOnlyColor = true
      break
    end
  end
  Assert.isTrue(
    sawEmbeddedOnlyColor,
    "compiled female pixels must follow each object's own decoded OAM palette bank, not the raw template "
      .. "selector treated as a local bank index"
  )
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

-- The pinned source (src/oaks_speech_obj.c, sSpriteTemplates) assigns exactly
-- one explicit OBJ palette selector per Oak-speech resource set: resourceSet
-- 1 (male) selects 0, resourceSet 2 (female) selects 1, and resourceSet 5
-- (ball/Marill) selects 4 for every sprite built from it. Selector zero must
-- resolve like any other explicit selector, never as an absent value.
local sourceSelectorByResourceSet = { [1] = 0, [2] = 1, [5] = 4 }

function T.oak_speech_selectors_match_pinned_source_sprite_templates(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")

  Assert.equal(IntroAssets.genderSelectors.male.paletteOverride, sourceSelectorByResourceSet[1], "male selector")
  Assert.equal(IntroAssets.genderSelectors.female.paletteOverride, sourceSelectorByResourceSet[2], "female selector")
  Assert.equal(
    IntroAssets.marill.paletteOverride,
    sourceSelectorByResourceSet[5],
    "marill selector matches its resource set's source template"
  )
  Assert.equal(
    IntroAssets.marill_appear.paletteOverride,
    sourceSelectorByResourceSet[5],
    "marill_appear selector matches its resource set's source template"
  )
  Assert.equal(
    IntroAssets.ball_open.paletteOverride,
    sourceSelectorByResourceSet[5],
    "ball_open shares resourceSet 5 with Marill and must select the same source palette (4), not an adjacent bank"
  )

  local bundle = assert(IntroAssetCompiler.compile(romFs))
  for id, resourceSet in pairs({ ball_open = 5, marill_appear = 5, marill = 5, gender_male = 1, gender_female = 2 }) do
    local widget = assert(bundle.manifest.widgets[id], id .. " widget present")
    local provenance = widget.provenance or {}
    local recordedSelector
    for key, value in pairs(provenance) do
      if type(value) == "number" and (tostring(key):find("pal") or tostring(key):find("slot")) then
        recordedSelector = value
      end
    end
    Assert.equal(
      recordedSelector,
      sourceSelectorByResourceSet[resourceSet],
      id .. " provenance must record the resolved source palette selector actually used to rasterize it"
    )
  end
end

function T.critical_widget_geometry_and_centers_survive_palette_resolution(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local widgets = bundle.manifest.widgets

  local expectedCenters = {
    gender_female = { x = 192, y = 104 },
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
end

function T.gender_selector_frame_highlight_semantics_are_generated(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local selector = bundle.manifest.genderSelector
  if selector == nil then
    error(
      "compiled intro manifest has no semantic gender-selector frame data (neutral surface plus per-button "
        .. "pulse-tone and accent masks); the renderer would have to tint portraits instead",
      0
    )
  end
  Assert.notNil(selector.neutral, "neutral selector surface is present")
  Assert.notNil(selector.defaultTone, "source default tone is preserved for the sine pulse")
  for _, gender in ipairs({ "male", "female" }) do
    local button = assert(selector.buttons and selector.buttons[gender], gender .. " selector button entry present")
    Assert.notNil(button.pulseMask, gender .. " pulse-tone mask is present")
    Assert.notNil(button.accentMask, gender .. " selected/unselected accent mask is present")
    Assert.notNil(button.bounds, gender .. " selector button source bounds are present")
  end
end

return RomSuite.fromFacts(T)
