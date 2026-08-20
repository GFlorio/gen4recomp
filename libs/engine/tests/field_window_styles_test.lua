-- FieldWindowStyles contract tests: the immutable style catalogue built once
-- from the generated field-UI manifest. Built-ins come from the manifest
-- (hgss.signpost / hgss.trainer_tip, with per-source-type signpost geometry
-- derived from wayfinding presence); the catalogue holds production-owned
-- built-ins only -- no external descriptor registration. resolve(id) returns
-- the stored record -- unknown ids return nil -- and semanticStyleId maps the
-- handwritten sign/trainer_tip appearances to the built-in constants. Pure
-- domain module: no love, no I/O.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")

local T = {
  tests = {},
}

local FULL_WIDTH_TEXT = { x = 16, y = 152, width = 216, height = 32 }
local GRAPHIC_TEXT = { x = 72, y = 152, width = 160, height = 32 }
local GRAPHIC_REGION = { x = 16, y = 152, width = 56, height = 32 }

local function styles()
  return FieldWindowStyles.new(FieldUiFixture.manifest())
end

local function stylesFromManifest(manifest)
  return FieldWindowStyles.new(manifest)
end

function T.tests.builtin_styles_resolve_with_the_canonical_geometry()
  local catalogue = styles()
  local signpost = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.SIGNPOST))
  Assert.deepEqual(signpost.contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(signpost.assets, "styles carry no asset-replacement ids")
  -- Type 0/1 reserve the wayfinding graphic; every other corpus type uses
  -- the full-width text region.
  Assert.deepEqual(signpost.types[0].contentGeometry, GRAPHIC_TEXT)
  Assert.deepEqual(signpost.types[0].graphicRegion, GRAPHIC_REGION)
  Assert.deepEqual(signpost.types[1].contentGeometry, GRAPHIC_TEXT)
  Assert.deepEqual(signpost.types[2].contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(signpost.types[2].graphicRegion)

  local trainerTip = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.TRAINER_TIP))
  Assert.deepEqual(trainerTip.contentGeometry, FULL_WIDTH_TEXT)
end

-- Every corpus signpost source type resolves with the canonical geometry,
-- preserving the raw source numbers.
function T.tests.every_corpus_source_type_resolves_with_canonical_geometry()
  local signpost = assert(styles():resolve(FieldWindowStyles.BUILTIN.SIGNPOST))
  for _, sourceType in ipairs(FieldUiFixture.CORPUS_SOURCE_TYPES) do
    local entry = signpost.types[sourceType]
    Assert.isTrue(type(entry) == "table", "source type " .. sourceType .. " must resolve in the signpost style")
    Assert.equal(entry.sourceType, sourceType, "the raw source number must be preserved")
    if sourceType == 0 or sourceType == 1 then
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

-- Wayfinding presence in the manifest drives the per-type graphic region,
-- not hard-coded source types.
function T.tests.wayfinding_presence_in_the_manifest_drives_the_graphic_region()
  local manifest = FieldUiFixture.manifest()
  manifest.signposts.types[5].wayfinding = { [0] = { x = 0, y = 24, width = 48, height = 32 } }
  local signpost = assert(stylesFromManifest(manifest):resolve(FieldWindowStyles.BUILTIN.SIGNPOST))
  Assert.deepEqual(
    signpost.types[5].contentGeometry,
    GRAPHIC_TEXT,
    "a manifest wayfinding map gives the type the graphic text region"
  )
  Assert.deepEqual(signpost.types[5].graphicRegion, GRAPHIC_REGION)
  Assert.isNil(signpost.types[3].graphicRegion, "a type without a wayfinding map stays full width")
end

-- The manifest is the catalogue's authority: a missing signposts section is
-- a programming/composition error, not a plausible empty catalogue.
function T.tests.missing_manifest_sections_fail_loudly()
  Assert.throws(function()
    FieldWindowStyles.new({ schema = "g4-field-ui-v3", assets = {} })
  end)
  Assert.throws(function()
    FieldWindowStyles.new({ assets = { ["hgss.signpost.tiles"] = { image = "x" } } })
  end)
end

function T.tests.semantic_style_ids_map_to_the_builtin_constants()
  Assert.equal(FieldWindowStyles.semanticStyleId("sign"), FieldWindowStyles.BUILTIN.SIGNPOST)
  Assert.equal(FieldWindowStyles.semanticStyleId("trainer_tip"), FieldWindowStyles.BUILTIN.TRAINER_TIP)
  Assert.isNil(FieldWindowStyles.semanticStyleId("mod.route_sign"), "a raw style id is not a semantic alias")
  Assert.isNil(FieldWindowStyles.semanticStyleId("bogus"))
end

-- resolve() is the strict lookup boundary: an id the catalogue does not
-- store returns nil.
function T.tests.unknown_ids_resolve_to_nil()
  local catalogue = styles()
  Assert.isNil(catalogue:resolve("no.such.style"), "unknown ids resolve to nil")
end

return T
