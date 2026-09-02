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

function T.source_palette_table_allocates_the_pinned_oak_absolute_banks(romFs)
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local resolution = assert(IntroAssets.genderSelectors.male.resourceResolution)
  local records = readPaletteRecords(romFs, resolution)
  for _, expected in ipairs({
    { vram = 3, objectId = 2, bankCount = 1, label = "male selector" },
    { vram = 3, objectId = 3, bankCount = 1, label = "female selector" },
    { vram = 1, objectId = 7, bankCount = 2, label = "Marill and ball opening" },
  }) do
    local record
    for _, candidate in ipairs(records) do
      if candidate.objectId == expected.objectId then
        record = candidate
        break
      end
    end
    record = assert(record, expected.label .. " palette record is present")
    Assert.equal(record.vram, expected.vram, expected.label .. " target engine is source-defined")
    Assert.equal(record.objectId, expected.objectId, expected.label .. " owner resource is source-defined")
    Assert.equal(record.bankCount, expected.bankCount, expected.label .. " bank count is source-defined")
  end
end

function T.shrink_frames_are_portrait_compositions(romFs)
  local IntroAssetCompiler = require("romdump.src.digest.IntroAssetCompiler")
  local IntroAssets = require("romdump.src.config.IntroAssets")
  local bundle = assert(IntroAssetCompiler.compile(romFs))

  for _, gender in ipairs({ "male", "female" }) do
    local id = "shrink_" .. gender
    local widget = assert(bundle.manifest.widgets[id], id .. " present")
    local spec = IntroAssets.shrink[gender]
    local expectedOrder = spec.chars
    Assert.equal(#widget.frames, #expectedOrder, id .. " frame count matches replacement order")
    Assert.isTrue(widget.width > 16 and widget.height > 16, id .. " frames are portrait-sized")
    Assert.equal(widget.provenance.screenMember, 9, id .. " provenance identifies the portrait screen")
    local members = {}
    for _, dependency in ipairs(bundle.dependencies.dependencies) do
      if dependency.role:match("^" .. id .. ":char:") then
        members[#members + 1] = dependency.memberId
      end
    end
    Assert.deepEqual(members, expectedOrder, id .. " preserves source replacement order")
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
  Assert.isNil(bundle.manifest.profileConfirmation)
  Assert.isNil(bundle.manifest.genderSelector.buttons.male.hitBounds)
  for _, id in ipairs({ "confirmation_yes", "confirmation_no" }) do
    Assert.isNil(widgets[id], id .. " is not a generated asset after TextButton migration")
  end
end

return RomSuite.fromFacts(T)
