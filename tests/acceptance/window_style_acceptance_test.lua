-- Production-composed window-style contracts: the runtime must construct the
-- FieldWindowStyleRegistry from the generated field-UI manifest and seal it
-- before scripts run, and the built-in hgss.dialogue / hgss.signpost /
-- hgss.trainer_tip styles must carry the canonical signpost presentation
-- geometry for every source type found in the script corpus, preserving the
-- raw source type numbers. Styles own only presentation records (id, base,
-- role, contentGeometry, graphicRegion, types): they must not advertise
-- frame/mapGraphic asset replacement or text colors, a derived style must
-- report its own identity rather than its base's, and resolve() must hand
-- out copies so a caller can never mutate the sealed catalogue. Style
-- definitions carry no input or script behavior, and nothing here renders.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "signpost", "registry" },
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
-- window width).
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
-- HGSS assets itself), no text colors, and a preserved identity.
local function assertPresentationRecord(style, id, label)
  Assert.isNil(style.assets, label .. " must not advertise frame/mapGraphic asset replacement")
  Assert.isNil(style.textColors, label .. " must not carry text colors")
  Assert.equal(style.id, id, label .. " must report its own id")
end

-- resolve() hands out a copy: mutating a returned record must never reach
-- the sealed catalogue, so a later resolve of the same style is unchanged.
local function assertResolveReturnsCopies(registry, id, label)
  local first = assert(registry:resolve(id))
  local originalX = first.contentGeometry.x
  first.contentGeometry.x = 999
  local second = assert(registry:resolve(id))
  Assert.equal(second.contentGeometry.x, originalX, label .. " resolve must return a deep copy, not the sealed record")
end

-- resolve() may return nil for an unknown id; the tests assert the id
-- resolves and hand the asserted record onward.
local function resolveStyle(registry, id, message)
  local style = registry:resolve(id)
  Assert.isTrue(type(style) == "table", message)
  return assert(style, message)
end

function T.tests.sealed_runtime_registry_resolves_builtin_styles_for_every_corpus_signpost_type()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({ versionId = "heartgold", map = "MAP_NEW_BARK", save = "fresh" })
  local ok, err = xpcall(function()
    ---@diagnostic disable-next-line: undefined-field -- the runtime registry surface is the contract under test
    local registry = game.runtime.windowStyles
    Assert.isTrue(
      type(registry) == "table",
      "the production runtime must expose the sealed window style registry, got: " .. tostring(registry)
    )
    Assert.equal(registry.sealed, true, "the runtime registry must be sealed before scripts run")

    local dialogue = resolveStyle(registry, "hgss.dialogue", "hgss.dialogue must resolve as a built-in style")
    Assert.equal(dialogue.role, "dialogue", "the dialogue style must declare its role")
    Assert.deepEqual(dialogue.contentGeometry, FULL_WIDTH_TEXT, "dialogue content geometry")

    local trainerTip = resolveStyle(registry, "hgss.trainer_tip", "hgss.trainer_tip must resolve as a built-in style")
    Assert.equal(trainerTip.role, "trainer_tip", "the trainer-tip style must declare its role")
    Assert.deepEqual(trainerTip.contentGeometry, FULL_WIDTH_TEXT, "trainer-tip content geometry")

    local signpost = resolveStyle(registry, "hgss.signpost", "hgss.signpost must resolve as a built-in style")
    Assert.equal(signpost.role, "signpost", "the signpost style must declare its role")
    Assert.deepEqual(signpost.contentGeometry, FULL_WIDTH_TEXT, "signpost content geometry")

    for _, sourceType in ipairs(CORPUS_SOURCE_TYPES) do
      assertStyleGeometry(signpost, sourceType, "every corpus signpost source type must resolve")
    end

    assertResolveReturnsCopies(registry, "hgss.signpost", "the signpost style")
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

-- A boot-config derived style resolves through the production pre-seal
-- registration seam with its own flat identity (id, no base) and the
-- base's presentation inherited, and resolve() copies protect both the
-- derived record and the sealed catalogue from caller mutation.
function T.tests.boot_config_derived_style_reports_its_own_identity_and_returns_copies()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      windowStyleDescriptors = {
        {
          id = "mod.route_sign",
          base = "hgss.signpost",
        },
      },
    },
  })
  local ok, err = xpcall(function()
    ---@diagnostic disable-next-line: undefined-field -- the runtime registry surface is the contract under test
    local registry = game.runtime.windowStyles
    Assert.isTrue(type(registry) == "table", "the production runtime must expose the sealed window style registry")
    Assert.equal(registry.sealed, true, "the runtime registry must be sealed before scripts run")

    local mod = resolveStyle(registry, "mod.route_sign", "the mod style must resolve through the sealed registry")
    Assert.equal(mod.id, "mod.route_sign", "a derived style must never report its base's id")
    Assert.isNil(mod.base, "a resolved style must never report a base")
    Assert.equal(mod.role, "signpost", "the derived style inherits the base role")
    Assert.deepEqual(mod.contentGeometry, FULL_WIDTH_TEXT, "the derived style inherits the base content geometry")
    assertStyleGeometry(mod, 0, "the derived style inherits the graphic-region geometry")
    assertStyleGeometry(mod, 2, "the derived style inherits the full-width geometry")

    assertResolveReturnsCopies(registry, "mod.route_sign", "the derived style")
    assertPresentationRecord(mod, "mod.route_sign", "the derived style")
    Assert.equal(game:renderAttempts(), 0, "style definitions must not render")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
