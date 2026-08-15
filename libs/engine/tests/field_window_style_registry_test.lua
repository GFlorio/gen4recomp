-- FieldWindowStyleRegistry contract tests: the per-runtime window-style
-- catalogue registers fully validated descriptors, rejects duplicates,
-- reserved hgss.* ids, unknown roles, unknown bases, and base cycles, and
-- resolves inheritance exactly once at seal into flat records that carry
-- only presentation fields (id, role, contentGeometry, graphicRegion, types)
-- -- never frame/mapGraphic asset replacement or text colors. A derived
-- record reports its own id, and resolve() hands out a deep copy so callers
-- can never mutate the sealed catalogue.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldWindowStyleRegistry = require("libs.engine.src.FieldWindowStyleRegistry")

local T = {
  tests = {},
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local function registry()
  return FieldWindowStyleRegistry.new()
end

local function fullDescriptor(overrides)
  local value = {
    id = "my_mod.notice",
    role = "signpost",
    contentGeometry = { x = 16, y = 152, width = 216, height = 32 },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function sealedRegistry(descriptors)
  local r = registry()
  for _, descriptor in ipairs(descriptors) do
    r:register(descriptor)
  end
  r:seal()
  return r
end

function T.tests.base_less_descriptor_registers_and_resolves_flat_after_seal()
  local r = sealedRegistry({ fullDescriptor() })
  Assert.equal(r.sealed, true, "the registry exposes the sealed flag")
  local style = assert(r:resolve("my_mod.notice"))
  Assert.isTrue(type(style) == "table", "resolve returns a flat record")
  Assert.equal(style.id, "my_mod.notice")
  Assert.isNil(style.base, "resolved records are flat")
  Assert.equal(style.role, "signpost")
  Assert.deepEqual(style.contentGeometry, fullDescriptor().contentGeometry)
  Assert.isNil(style.assets, "styles never advertise asset replacement")
  Assert.isNil(style.textColors, "styles never carry text colors")
end

function T.tests.descriptor_validation_requires_the_full_shape()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register({})
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ id = "" }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    local descriptor = fullDescriptor()
    descriptor.role = nil
    registry():register(descriptor)
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    local descriptor = fullDescriptor()
    descriptor.contentGeometry = nil
    registry():register(descriptor)
  end)
end

function T.tests.unknown_roles_are_rejected()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ role = "menu" }))
  end)
end

function T.tests.invalid_geometry_is_rejected()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ contentGeometry = { x = 0, y = 0, width = 0.5, height = 4 } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ contentGeometry = { x = -1, y = 0, width = 4, height = 4 } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ contentGeometry = { x = 0, y = 0, width = 0, height = 4 } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ contentGeometry = { x = 0, y = 0, width = 4 } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ graphicRegion = { x = 0, y = 0, width = -4, height = 4 } }))
  end)
end

function T.tests.duplicate_ids_are_rejected()
  local r = registry()
  r:register(fullDescriptor())
  throwsCode("WINDOW_STYLE_DUPLICATE_ID", function()
    r:register(fullDescriptor({ role = "dialogue" }))
  end)
end

function T.tests.the_hgss_prefix_is_reserved_for_builtins()
  throwsCode("WINDOW_STYLE_RESERVED_ID", function()
    registry():register(fullDescriptor({ id = "hgss.signpost" }))
  end)
  throwsCode("WINDOW_STYLE_RESERVED_ID", function()
    registry():register(fullDescriptor({ id = "hgss.some_future_style" }))
  end)
end

function T.tests.unknown_bases_are_rejected_at_seal()
  local r = registry()
  r:register(fullDescriptor({ id = "my_mod.notice", base = "no.such.style" }))
  throwsCode("WINDOW_STYLE_UNKNOWN_BASE", function()
    r:seal()
  end)
end

function T.tests.base_cycles_are_detected_at_seal()
  local r = registry()
  r:register(fullDescriptor({ id = "my_mod.a", base = "my_mod.b" }))
  r:register(fullDescriptor({ id = "my_mod.b", base = "my_mod.a" }))
  throwsCode("WINDOW_STYLE_BASE_CYCLE", function()
    r:seal()
  end)
end

function T.tests.inheritance_resolves_once_into_flat_records()
  local base = fullDescriptor({ id = "my_mod.base" })
  local derived = fullDescriptor({ id = "my_mod.notice", base = "my_mod.base" })
  local r = registry()
  r:register(base)
  r:register(derived)
  -- Mutation of the caller's descriptor after registration must not leak
  -- into the sealed records.
  derived.contentGeometry.width = 1
  base.role = "dialogue"
  r:seal()

  local notice = assert(r:resolve("my_mod.notice"))
  Assert.equal(notice.role, "signpost", "role is inherited from the base")
  Assert.deepEqual(notice.contentGeometry, fullDescriptor().contentGeometry, "inherited geometry survives")
  Assert.equal(notice.id, "my_mod.notice", "a derived style reports its own id")
  Assert.isNil(notice.base, "a derived style never reports a base")
  local resolvedBase = assert(r:resolve("my_mod.base"))
  Assert.equal(resolvedBase.id, "my_mod.base", "the base record keeps its own identity")
  Assert.isNil(resolvedBase.base, "resolved records are flat: no live base chain")
end

function T.tests.post_seal_register_and_double_seal_are_rejected()
  local r = sealedRegistry({ fullDescriptor() })
  throwsCode("WINDOW_STYLE_ALREADY_SEALED", function()
    r:register(fullDescriptor({ id = "my_mod.second" }))
  end)
  throwsCode("WINDOW_STYLE_ALREADY_SEALED", function()
    r:seal()
  end)
end

function T.tests.resolve_before_seal_raises_and_unknown_ids_return_nil()
  local r = registry()
  r:register(fullDescriptor())
  throwsCode("WINDOW_STYLE_NOT_SEALED", function()
    r:resolve("my_mod.notice")
  end)
  r:seal()
  Assert.isNil(r:resolve("no.such.style"), "unknown ids resolve to nil")
end

function T.tests.derived_descriptors_may_override_geometry_role_and_types()
  local base = fullDescriptor({ id = "my_mod.base", types = { [0] = { sourceType = 0 } } })
  local derived = fullDescriptor({
    id = "my_mod.notice",
    base = "my_mod.base",
    contentGeometry = { x = 72, y = 152, width = 160, height = 32 },
    types = { [2] = { sourceType = 2, contentGeometry = { x = 16, y = 152, width = 216, height = 32 } } },
  })
  local r = sealedRegistry({ base, derived })
  local notice = assert(r:resolve("my_mod.notice"))
  Assert.deepEqual(notice.contentGeometry, { x = 72, y = 152, width = 160, height = 32 })
  Assert.isNil(notice.types[0], "the derived types map replaces the inherited one")
  Assert.equal(notice.types[2].sourceType, 2)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ id = "my_mod.bad", types = { [0] = { sourceType = -1 } } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(
      fullDescriptor({ id = "my_mod.bad", types = { [0] = { sourceType = 0, graphicRegion = { x = 0 } } } })
    )
  end)
end

-- Type entries are keyed by their own sourceType: a key/sourceType mismatch
-- is a malformed descriptor, not a plausible alias.
function T.tests.type_entries_must_be_keyed_by_their_own_source_type()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ id = "my_mod.bad", types = { [2] = { sourceType = 3 } } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ id = "my_mod.bad", types = { [2] = {} } }))
  end)
end

function T.tests.resolve_returns_a_deep_copy_that_cannot_mutate_the_catalogue()
  local r = sealedRegistry({ fullDescriptor() })
  local style = assert(r:resolve("my_mod.notice"))
  style.contentGeometry.x = 999
  style.types = { [0] = { sourceType = 0 } }
  local again = assert(r:resolve("my_mod.notice"))
  Assert.equal(again.contentGeometry.x, 16, "mutating a returned record never reaches the catalogue")
  Assert.isNil(again.types, "added fields on a returned copy never reach the catalogue")
end

return T
