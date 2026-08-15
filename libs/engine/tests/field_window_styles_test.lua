-- FieldWindowStyles contract tests: the immutable style catalogue built once
-- from the generated field-UI manifest plus external descriptors. Built-ins
-- come from the manifest (hgss.dialogue / hgss.signpost / hgss.trainer_tip,
-- with per-source-type signpost geometry derived from wayfinding presence);
-- external descriptors must be complete records (no inheritance -- a base
-- field is rejected) and are validated, copied, and rejected on reserved
-- hgss. ids or duplicates at construction. resolve(id) returns the stored
-- record -- unknown ids return nil -- and semanticStyleId maps the
-- handwritten sign/trainer_tip appearances to the built-in constants. Pure
-- domain module: no love, no I/O.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")

local T = {
  tests = {},
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local FULL_WIDTH_TEXT = { x = 16, y = 152, width = 216, height = 32 }
local GRAPHIC_TEXT = { x = 72, y = 152, width = 160, height = 32 }
local GRAPHIC_REGION = { x = 16, y = 152, width = 56, height = 32 }

local function completeDescriptor(overrides)
  local value = {
    id = "mod.route_sign",
    role = "signpost",
    contentGeometry = { x = 16, y = 152, width = 216, height = 32 },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function styles(descriptors)
  return FieldWindowStyles.new(FieldUiFixture.manifest(), descriptors or {})
end

local function stylesFromManifest(manifest, descriptors)
  return FieldWindowStyles.new(manifest, descriptors or {})
end

function T.tests.builtin_styles_resolve_with_the_canonical_geometry()
  local catalogue = styles()
  local dialogue = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.DIALOGUE))
  Assert.equal(dialogue.role, "dialogue")
  Assert.deepEqual(dialogue.contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(dialogue.assets, "styles carry no asset-replacement ids")

  local signpost = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.SIGNPOST))
  Assert.equal(signpost.role, "signpost")
  Assert.deepEqual(signpost.contentGeometry, FULL_WIDTH_TEXT)
  -- Type 0/1 reserve the wayfinding graphic; every other corpus type uses
  -- the full-width text region.
  Assert.deepEqual(signpost.types[0].contentGeometry, GRAPHIC_TEXT)
  Assert.deepEqual(signpost.types[0].graphicRegion, GRAPHIC_REGION)
  Assert.deepEqual(signpost.types[1].contentGeometry, GRAPHIC_TEXT)
  Assert.deepEqual(signpost.types[2].contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(signpost.types[2].graphicRegion)

  local trainerTip = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.TRAINER_TIP))
  Assert.equal(trainerTip.role, "trainer_tip")
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
  manifest.signposts.types[5].wayfinding = { [0] = { x = 0, y = 24, width = 192, height = 8 } }
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
    FieldWindowStyles.new({ schema = "g4-field-ui-v3", assets = {} }, {})
  end)
  Assert.throws(function()
    FieldWindowStyles.new({ assets = { ["hgss.signpost.tiles"] = { image = "x" } } }, {})
  end)
end

function T.tests.semantic_style_ids_map_to_the_builtin_constants()
  Assert.equal(FieldWindowStyles.semanticStyleId("sign"), FieldWindowStyles.BUILTIN.SIGNPOST)
  Assert.equal(FieldWindowStyles.semanticStyleId("trainer_tip"), FieldWindowStyles.BUILTIN.TRAINER_TIP)
  Assert.isNil(FieldWindowStyles.semanticStyleId("mod.route_sign"), "a raw style id is not a semantic alias")
  Assert.isNil(FieldWindowStyles.semanticStyleId("bogus"))
end

function T.tests.external_descriptors_validate_at_construction()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ id = "" }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ role = "frame" }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ contentGeometry = { x = 0, y = 0, width = -4, height = 8 } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ types = { { sourceType = 0 } } }) })
  end)
end

-- The complete-record shape: an empty descriptor and a descriptor missing a
-- required field are malformed, not plausible defaults.
function T.tests.descriptor_validation_requires_the_full_shape()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ {} })
  end)
  local function without(field)
    local descriptor = completeDescriptor()
    descriptor[field] = nil
    return descriptor
  end
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ without("role") })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ without("contentGeometry") })
  end)
end

function T.tests.unknown_roles_and_invalid_geometry_are_rejected()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ role = "menu" }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ contentGeometry = { x = 0, y = 0, width = 0.5, height = 4 } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ contentGeometry = { x = -1, y = 0, width = 4, height = 4 } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ contentGeometry = { x = 0, y = 0, width = 0, height = 4 } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ contentGeometry = { x = 0, y = 0, width = 4 } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ graphicRegion = { x = 0, y = 0, width = -4, height = 4 } }) })
  end)
end

-- Custom descriptors are complete records, not inheritance deltas: a base
-- field is rejected, naming the descriptor.
function T.tests.base_carrying_descriptors_are_rejected()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ id = "mod.derived", base = "hgss.signpost" }) })
  end)
end

-- Type entries are keyed by their own sourceType: a key/sourceType mismatch
-- or a malformed entry rect is a malformed descriptor, not a plausible alias.
function T.tests.type_entries_must_be_keyed_by_their_own_source_type()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ id = "mod.bad", types = { [2] = { sourceType = 3 } } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ id = "mod.bad", types = { [2] = {} } }) })
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    styles({ completeDescriptor({ id = "mod.bad", types = { [0] = { sourceType = 0, graphicRegion = { x = 0 } } } }) })
  end)
end

function T.tests.reserved_and_duplicate_ids_are_rejected()
  throwsCode("WINDOW_STYLE_RESERVED_ID", function()
    styles({ completeDescriptor({ id = "hgss.signpost" }) })
  end)
  throwsCode("WINDOW_STYLE_RESERVED_ID", function()
    styles({ completeDescriptor({ id = "hgss.custom" }) })
  end)
  throwsCode("WINDOW_STYLE_DUPLICATE_ID", function()
    styles({ completeDescriptor(), completeDescriptor() })
  end)
end

function T.tests.a_complete_mod_record_resolves_with_its_own_fields()
  local catalogue = styles({ completeDescriptor() })
  local mod = assert(catalogue:resolve("mod.route_sign"))
  Assert.equal(mod.id, "mod.route_sign")
  Assert.equal(mod.role, "signpost")
  Assert.deepEqual(mod.contentGeometry, FULL_WIDTH_TEXT)
  Assert.isNil(mod.base, "complete records carry no base")
  Assert.isNil(mod.assets)
end

function T.tests.resolve_returns_the_stored_record_without_copies()
  local catalogue = styles()
  local first = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.DIALOGUE))
  first.contentGeometry.x = 999
  local second = assert(catalogue:resolve(FieldWindowStyles.BUILTIN.DIALOGUE))
  Assert.equal(
    second.contentGeometry.x,
    999,
    "resolve hands out the stored record: consumers treat it as immutable by convention"
  )
  Assert.isNil(catalogue:resolve("no.such.style"), "unknown ids resolve to nil")
end

-- Descriptor input is copied once at construction: mutating the caller's
-- table afterwards never reaches the catalogue.
function T.tests.descriptor_mutation_after_construction_never_reaches_the_catalogue()
  local descriptor = completeDescriptor()
  local catalogue = styles({ descriptor })
  descriptor.contentGeometry.x = 999
  descriptor.role = "dialogue"
  local stored = assert(catalogue:resolve("mod.route_sign"))
  Assert.equal(stored.contentGeometry.x, 16, "the catalogue keeps its own copy")
  Assert.equal(stored.role, "signpost")
end

return T
