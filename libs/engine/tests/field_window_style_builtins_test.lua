-- FieldWindowStyleRegistry built-in loading contract: the three HGSS styles
-- are registered from the generated field-UI manifest shape (asset ids and
-- per-source-type wayfinding presence come from the manifest, not hard-coded
-- atlas rects), hgss.signpost preserves the raw corpus source numbers and
-- resolves the canonical type-0/1 graphic-region geometry, and the other
-- built-ins are thin full-width records.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldWindowStyleRegistry = require("libs.engine.src.FieldWindowStyleRegistry")

local T = {
  tests = {},
}

local FULL_WIDTH_TEXT = { x = 16, y = 152, width = 216, height = 32 }
local GRAPHIC_TEXT = { x = 72, y = 152, width = 160, height = 32 }
local GRAPHIC_REGION = { x = 16, y = 152, width = 56, height = 32 }

local function builtinRegistry(manifest)
  local r = FieldWindowStyleRegistry.new()
  r:registerBuiltins(manifest or FieldUiFixture.manifest())
  r:seal()
  return r
end

local function hasGraphicRegion(sourceType)
  return sourceType == 0 or sourceType == 1
end

function T.tests.the_three_builtins_resolve_with_their_manifest_asset_ids()
  local r = builtinRegistry()
  local dialogue = assert(r:resolve("hgss.dialogue"))
  Assert.equal(dialogue.id, "hgss.dialogue")
  Assert.equal(dialogue.role, "dialogue")
  Assert.equal(dialogue.assets.frame, "hgss.dialogue_frame.tiles")
  Assert.deepEqual(dialogue.contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(dialogue.types, "the dialogue style carries no per-type map")

  local trainerTip = assert(r:resolve("hgss.trainer_tip"))
  Assert.equal(trainerTip.role, "trainer_tip")
  Assert.equal(trainerTip.assets.frame, "hgss.signpost.tiles")
  Assert.deepEqual(trainerTip.contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(trainerTip.types, "the trainer-tip style carries no per-type map")

  local signpost = assert(r:resolve("hgss.signpost"))
  Assert.equal(signpost.role, "signpost")
  Assert.equal(signpost.assets.frame, "hgss.signpost.tiles")
  Assert.equal(signpost.assets.mapGraphic, "hgss.signpost.wayfinding")
  Assert.deepEqual(signpost.contentGeometry, FULL_WIDTH_TEXT, "the style-level geometry is the full window")
end

function T.tests.every_corpus_source_type_resolves_with_canonical_geometry()
  local signpost = assert(builtinRegistry():resolve("hgss.signpost"))
  for _, sourceType in ipairs(FieldUiFixture.CORPUS_SOURCE_TYPES) do
    local entry = signpost.types[sourceType]
    Assert.isTrue(type(entry) == "table", "source type " .. sourceType .. " must resolve in the signpost style")
    Assert.equal(entry.sourceType, sourceType, "the raw source number must be preserved")
    if hasGraphicRegion(sourceType) then
      Assert.deepEqual(entry.contentGeometry, GRAPHIC_TEXT, "type " .. sourceType .. " text region")
      Assert.deepEqual(entry.graphicRegion, GRAPHIC_REGION, "type " .. sourceType .. " graphic region")
      Assert.equal(
        entry.graphicRegion.x + entry.graphicRegion.width,
        entry.contentGeometry.x,
        "type " .. sourceType .. " graphic and text regions must not overlap"
      )
    else
      Assert.deepEqual(entry.contentGeometry, FULL_WIDTH_TEXT, "type " .. sourceType .. " text region")
      Assert.isNil(entry.graphicRegion, "type " .. sourceType .. " must not reserve a graphic region")
    end
  end
end

function T.tests.wayfinding_presence_in_the_manifest_drives_the_graphic_region()
  local manifest = FieldUiFixture.manifest()
  manifest.signposts.types[5].wayfinding = { x = 0, y = 24, width = 192, height = 8 }
  local signpost = assert(builtinRegistry(manifest):resolve("hgss.signpost"))
  Assert.deepEqual(
    signpost.types[5].contentGeometry,
    GRAPHIC_TEXT,
    "a manifest wayfinding rect gives the type the graphic text region"
  )
  Assert.deepEqual(signpost.types[5].graphicRegion, GRAPHIC_REGION)
  Assert.isNil(signpost.types[3].graphicRegion, "a type without a wayfinding rect stays full width")
end

function T.tests.builtins_cannot_be_replaced_by_mods()
  local r = FieldWindowStyleRegistry.new()
  r:registerBuiltins(FieldUiFixture.manifest())
  r:seal()
  Assert.isNil(assert(r:resolve("hgss.dialogue")).types, "hgss.dialogue keeps its own record shape")
  Assert.equal(assert(r:resolve("hgss.trainer_tip")).assets.frame, "hgss.signpost.tiles")
end

function T.tests.missing_manifest_sections_fail_loudly()
  local r = FieldWindowStyleRegistry.new()
  Assert.throws(function()
    r:registerBuiltins({ schema = "g4-field-ui-v2", assets = {} })
  end)
  local r2 = FieldWindowStyleRegistry.new()
  Assert.throws(function()
    r2:registerBuiltins({ assets = { ["hgss.signpost.tiles"] = { image = "x" } } })
  end)
end

return T
