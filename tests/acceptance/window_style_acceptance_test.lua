-- Production-composed window-style contracts: the runtime constructs the
-- immutable style catalogue from the generated field-UI manifest it already
-- validates, and the built-in hgss.dialogue / hgss.signpost /
-- hgss.trainer_tip styles carry the canonical signpost presentation geometry
-- for every source type found in the script corpus, preserving the raw
-- source type numbers. Styles own only presentation records (id, role,
-- contentGeometry, graphicRegion, types): they must not advertise
-- frame/mapGraphic asset replacement or text colors. Boot-config custom
-- descriptors and their rejection contracts live in
-- window_style_catalog_acceptance_test.lua; the high-level custom-style sign
-- journey lives in high_level_sign_acceptance_test.lua. Nothing here
-- renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "signpost", "catalog" },
  },
  tests = {},
}

-- Every signpost source type the real scr_seq corpus uses (opcodes 55/56),
-- audited and pinned by the producer configuration. The style definitions
-- must keep these raw numbers intact.
local CORPUS_SOURCE_TYPES = {
  0,
  1,
  2,
  3,
  4,
  5,
  8,
  9,
  10,
  11,
  13,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  23,
  28,
  29,
  30,
  33,
  34,
  39,
}

-- Canonical signpost content geometry: types 0/1 reserve a seven-tile
-- wayfinding graphic on the left, all other types use the full ordinary
-- window width.
local FULL_WIDTH_TEXT = { x = 16, y = 152, width = 216, height = 32 }
local GRAPHIC_TEXT = { x = 72, y = 152, width = 160, height = 32 }
local GRAPHIC_REGION = { x = 16, y = 152, width = 56, height = 32 }

local function hasGraphicRegion(sourceType)
  return sourceType == 0 or sourceType == 1
end

local function assertStyleGeometry(style, sourceType, label)
  local entry = style.types[sourceType]
  Assert.isTrue(type(entry) == "table", label .. " source type " .. sourceType .. " must resolve in the signpost style")
  Assert.equal(entry.sourceType, sourceType, label .. " source type number must be preserved")
  if hasGraphicRegion(sourceType) then
    Assert.deepEqual(entry.contentGeometry, GRAPHIC_TEXT, label .. " type " .. sourceType .. " text region")
    Assert.deepEqual(entry.graphicRegion, GRAPHIC_REGION, label .. " type " .. sourceType .. " graphic region")
    Assert.equal(
      entry.graphicRegion.x + entry.graphicRegion.width,
      entry.contentGeometry.x,
      label .. " type " .. sourceType .. " graphic and text regions must not overlap"
    )
  else
    Assert.deepEqual(entry.contentGeometry, FULL_WIDTH_TEXT, label .. " type " .. sourceType .. " text region")
    Assert.isNil(entry.graphicRegion, label .. " type " .. sourceType .. " must not reserve a graphic region")
  end
end

-- The shared presentation-record contract of every resolved style: no
-- frame/mapGraphic asset replacement (the renderer loads the fixed generated
-- HGSS assets itself) and no text colors.
local function assertPresentationRecord(style, id, label)
  Assert.isNil(style.assets, label .. " must not advertise frame/mapGraphic asset replacement")
  Assert.isNil(style.textColors, label .. " must not carry text colors")
  Assert.equal(style.id, id, label .. " must report its own id")
end

-- The production runtime exposes the immutable catalogue: every corpus
-- signpost source type resolves with the canonical built-in geometry, and
-- the resolved records stay presentation-only.
function T.tests.runtime_catalogue_resolves_builtin_styles_for_every_corpus_signpost_type()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({ versionId = "heartgold", map = "MAP_NEW_BARK", save = "fresh" })
  local ok, err = xpcall(function()
    local styles = game.runtime.windowStyles
    Assert.isTrue(type(styles) == "table", "the production runtime must expose the window style catalogue")

    local dialogue = assert(styles:resolve("hgss.dialogue"), "hgss.dialogue must resolve as a built-in style")
    Assert.equal(dialogue.role, "dialogue", "the dialogue style must declare its role")
    Assert.deepEqual(dialogue.contentGeometry, FULL_WIDTH_TEXT, "dialogue content geometry")

    local trainerTip = assert(styles:resolve("hgss.trainer_tip"), "hgss.trainer_tip must resolve as a built-in style")
    Assert.equal(trainerTip.role, "trainer_tip", "the trainer-tip style must declare its role")
    Assert.deepEqual(trainerTip.contentGeometry, FULL_WIDTH_TEXT, "trainer-tip content geometry")

    local signpost = assert(styles:resolve("hgss.signpost"), "hgss.signpost must resolve as a built-in style")
    Assert.equal(signpost.role, "signpost", "the signpost style must declare its role")
    Assert.deepEqual(signpost.contentGeometry, FULL_WIDTH_TEXT, "signpost content geometry")

    for _, sourceType in ipairs(CORPUS_SOURCE_TYPES) do
      assertStyleGeometry(signpost, sourceType, "every corpus signpost source type must resolve")
    end

    assertPresentationRecord(dialogue, "hgss.dialogue", "the dialogue style")
    assertPresentationRecord(trainerTip, "hgss.trainer_tip", "the trainer-tip style")
    assertPresentationRecord(signpost, "hgss.signpost", "the signpost style")
    Assert.equal(game:renderAttempts(), 0, "style definitions must not render")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
