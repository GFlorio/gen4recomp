-- Independent ROM oracle for the source-backed Oak profile-choice surfaces.
-- Geometry and resource facts are from pret/pokeheartgold, commit
-- f45f4fd1368e8809515540404408fd2bc71974a8, src/oaks_speech.c.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.G2dDecoder")
local Lz10 = require("romdump.src.digest.Lz10")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local genderBounds = {
  male = { x = 18, y = 25, width = 93, height = 148 },
  female = { x = 144, y = 25, width = 95, height = 148 },
}

local confirmation = {
  male = {
    scrollX = 0x88,
    yes = {
      scrollY = 0,
      bounds = { x = 138, y = 26, width = 115, height = 57 },
      textBounds = { x = 136, y = 48, width = 104, height = 24 },
    },
    no = {
      scrollY = 0x1AF,
      bounds = { x = 138, y = 108, width = 115, height = 56 },
      textBounds = { x = 136, y = 128, width = 104, height = 24 },
    },
  },
  female = {
    scrollX = 0,
    yes = {
      scrollY = 0,
      bounds = { x = 10, y = 26, width = 115, height = 57 },
      textBounds = { x = 16, y = 48, width = 104, height = 24 },
    },
    no = {
      scrollY = 0x1AF,
      bounds = { x = 10, y = 108, width = 115, height = 56 },
      textBounds = { x = 16, y = 128, width = 104, height = 24 },
    },
  },
}

local function member(archive, memberId)
  local bytes = assert(archive:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes))
  end
  return bytes
end

local function zeros(width, height)
  local values = {}
  for index = 1, width * height * 4 do
    values[index] = 0
  end
  return values
end

local function bytes(values)
  local chunks = {}
  for index = 1, #values, 4096 do
    chunks[#chunks + 1] = string.char(unpack(values, index, math.min(index + 4095, #values)))
  end
  return table.concat(chunks)
end

local function pixelValue(char, tile, x, y)
  local tileBytes = char.depth == 3 and 32 or 64
  local offset = tile * tileBytes
  if char.depth == 3 then
    local value = string.byte(char.tiles, offset + y * 4 + math.floor(x / 2) + 1)
    return x % 2 == 0 and value % 16 or math.floor(value / 16)
  end
  return string.byte(char.tiles, offset + y * 8 + x + 1)
end

-- Render only the source BG composition needed by this oracle. This is kept
-- separate from IntroAssetCompiler so a crop, palette-bank, or flip bug in the
-- producer cannot make its own expected pixels pass.
local function renderScreen(char, palette, screen, forcedBank)
  local rgba, values, banks = zeros(screen.width, screen.height), {}, {}
  local columns = screen.width / 8
  for row = 0, screen.height / 8 - 1 do
    for column = 0, columns - 1 do
      local entry = screen.entries[row * columns + column + 1]
      local bank = forcedBank or entry.palette
      for y = 0, 7 do
        for x = 0, 7 do
          local value = pixelValue(char, entry.tile, x, y)
          local dx = column * 8 + (entry.flipH and 7 - x or x)
          local dy = row * 8 + (entry.flipV and 7 - y or y)
          local position = dy * screen.width + dx + 1
          values[position], banks[position] = value, entry.palette
          if value ~= 0 then
            local color = palette.colors[value + 1 + (char.depth == 3 and bank * 16 or 0)]
            assert(color, "source screen references a missing palette color")
            local offset = (position - 1) * 4
            rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], rgba[offset + 4] = color.r, color.g, color.b, 255
          end
        end
      end
    end
  end
  return { width = screen.width, height = screen.height, rgba = bytes(rgba), values = values, banks = banks }
end

local function crop(surface, bounds, scrollX, scrollY)
  local rgba = zeros(bounds.width, bounds.height)
  for y = 0, bounds.height - 1 do
    for x = 0, bounds.width - 1 do
      local sx = (bounds.x + x + scrollX) % surface.width
      local sy = (bounds.y + y + scrollY) % surface.height
      local source = (sy * surface.width + sx) * 4 + 1
      local target = (y * bounds.width + x) * 4 + 1
      for channel = 0, 3 do
        rgba[target + channel] = string.byte(surface.rgba, source + channel)
      end
    end
  end
  return { width = bounds.width, height = bounds.height, rgba = bytes(rgba) }
end

local function opaque(surface)
  local rgba = {}
  for index = 1, #surface.rgba, 4 do
    rgba[index], rgba[index + 1], rgba[index + 2] = string.byte(surface.rgba, index, index + 2)
    rgba[index + 3] = 255
  end
  return { width = surface.width, height = surface.height, rgba = bytes(rgba) }
end

local function mask(surface, value)
  local rgba = zeros(surface.width, surface.height)
  for index, sourceValue in ipairs(surface.values) do
    if sourceValue == value and surface.banks[index] == 0 then
      local offset = (index - 1) * 4
      rgba[offset + 1], rgba[offset + 2], rgba[offset + 3], rgba[offset + 4] = 255, 255, 255, 255
    end
  end
  return { width = surface.width, height = surface.height, rgba = bytes(rgba) }
end

local function assertImage(cache, record, expected, label)
  Assert.equal(record.width, expected.width, label .. " width")
  Assert.equal(record.height, expected.height, label .. " height")
  local width, height, rgba = PngReader.rgba(assert(cache[record.image], label .. " PNG is present"))
  Assert.equal(width, expected.width, label .. " PNG width")
  Assert.equal(height, expected.height, label .. " PNG height")
  Assert.equal(rgba, expected.rgba, label .. " pixels")
end

local function sourceSurface(archive, charId, paletteId, screenId, label, forcedBank)
  local char = assert(G2dDecoder.decodeChar(member(archive, charId), { label = label .. " char" }))
  local palette = assert(G2dDecoder.decodePalette(member(archive, paletteId), { label = label .. " palette" }))
  local screen = assert(G2dDecoder.decodeScreen(member(archive, screenId), { label = label .. " screen" }))
  return renderScreen(char, palette, screen, forcedBank)
end

function T.source_composition_matches_v6_profile_choice_assets(romFs, versionId)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local bundle = assert(IntroAssetCompiler.compile(romFs))
  local manifest = bundle.manifest
  Assert.equal(manifest.schemaVersion, 6)
  Assert.isNil(manifest.genderSelector.neutral)

  local archive = assert(romFs:openNarc("intro"))
  local paletteId = versionId == "heartgold" and 30 or 31
  local gender = sourceSurface(archive, 32, paletteId, 51, "gender selector")
  for _, name in ipairs({ "male", "female" }) do
    local button = assert(manifest.genderSelector.buttons[name])
    Assert.deepEqual(button.bounds, genderBounds[name], name .. " bounds")
    Assert.deepEqual(button.hitBounds, genderBounds[name], name .. " hit bounds")
    local expectedBacking = opaque(crop(gender, genderBounds[name], 0, 0))
    assertImage(bundle.assets, button.backing, expectedBacking, name .. " backing")
    local pulseValue = name == "male" and 12 or 14
    local accentValue = name == "male" and 13 or 15
    assertImage(
      bundle.assets,
      button.pulseMask,
      crop(mask(gender, pulseValue), genderBounds[name], 0, 0),
      name .. " pulse mask"
    )
    assertImage(
      bundle.assets,
      button.accentMask,
      crop(mask(gender, accentValue), genderBounds[name], 0, 0),
      name .. " accent mask"
    )
  end

  local base = sourceSurface(archive, 37, 33, 48, "profile confirmation base", 0)
  local focus = sourceSurface(archive, 42, 33, 50, "profile confirmation focus", 0)
  for _, name in ipairs({ "male", "female" }) do
    for _, choice in ipairs({ "yes", "no" }) do
      local source = confirmation[name][choice]
      local record = assert(manifest.profileConfirmation.buttons[name][choice])
      Assert.deepEqual(record.bounds, source.bounds, name .. " " .. choice .. " bounds")
      Assert.deepEqual(record.textBounds, source.textBounds, name .. " " .. choice .. " text bounds")
      assertImage(
        bundle.assets,
        record.base,
        crop(base, source.bounds, confirmation[name].scrollX, source.scrollY),
        name .. " " .. choice .. " base"
      )
      assertImage(
        bundle.assets,
        record.focus,
        crop(focus, source.bounds, confirmation[name].scrollX, source.scrollY),
        name .. " " .. choice .. " focus"
      )
    end
  end
end

return RomSuite.fromFacts(T)
