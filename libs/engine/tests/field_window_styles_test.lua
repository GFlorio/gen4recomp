-- FieldWindowStyles contract tests: the immutable style catalogue built once
-- from the generated field-UI manifest plus external descriptors. Built-ins
-- come from the manifest (hgss.dialogue / hgss.signpost / hgss.trainer_tip,
-- with per-source-type signpost geometry derived from wayfinding presence);
-- external descriptors must be complete records (no inheritance) and are
-- validated, copied, and rejected on reserved hgss. ids or duplicates at
-- construction. resolve(id) returns the stored record -- unknown ids return
-- nil -- and semanticStyleId maps the handwritten sign/trainer_tip
-- appearances to the built-in constants. Pure domain module: no love, no I/O.

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
    contentGeometry = FULL_WIDTH_TEXT,
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function styles(descriptors)
  return FieldWindowStyles.new(FieldUiFixture.manifest(), descriptors or {})
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

return T
