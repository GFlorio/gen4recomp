-- FieldWindowStyleRegistry contract tests: the per-runtime window-style
-- catalogue registers fully validated descriptors, rejects duplicates,
-- reserved hgss.* ids, unknown roles/assets, unknown bases, and base
-- cycles, and resolves inheritance exactly once at seal into immutable
-- flat records. The registry carries presentation information only; no
-- input, script wait behavior, or message source.

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
    assets = { frame = "asset.my_mod.notice_frame" },
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
  Assert.isTrue(type(style) == "table", "resolve returns the sealed record")
  Assert.equal(style.id, "my_mod.notice")
  Assert.equal(style.role, "signpost")
  Assert.equal(style.assets.frame, "asset.my_mod.notice_frame")
  Assert.deepEqual(style.contentGeometry, fullDescriptor().contentGeometry)
  Assert.isTrue(r:resolve("my_mod.notice") == style, "resolve returns the same sealed record object")
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
    descriptor.assets = nil
    registry():register(descriptor)
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    local descriptor = fullDescriptor()
    descriptor.contentGeometry = nil
    registry():register(descriptor)
  end)
end

function T.tests.unknown_roles_and_asset_keys_are_rejected()
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ role = "menu" }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ assets = {} }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ assets = { border = "asset.border" } }))
  end)
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ assets = { frame = "" } }))
  end)
end

function T.tests.invalid_geometry_and_text_colors_are_rejected()
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
  throwsCode("WINDOW_STYLE_INVALID_DESCRIPTOR", function()
    registry():register(fullDescriptor({ textColors = "red" }))
  end)
end

function T.tests.text_colors_are_accepted_on_a_descriptor()
  local r = sealedRegistry({
    fullDescriptor({ textColors = { body = { 255, 255, 255 }, shadow = { 0, 0, 0 } } }),
  })
  Assert.deepEqual(assert(r:resolve("my_mod.notice")).textColors, { body = { 255, 255, 255 }, shadow = { 0, 0, 0 } })
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

function T.tests.inheritance_resolves_once_into_immutable_flat_records()
  local base = fullDescriptor({
    id = "my_mod.base",
    assets = { frame = "asset.my_mod.base_frame", mapGraphic = "asset.my_mod.map" },
  })
  local derived = fullDescriptor({
    id = "my_mod.notice",
    base = "my_mod.base",
    assets = { frame = "asset.my_mod.notice_frame" },
  })
  local r = registry()
  r:register(base)
  r:register(derived)
  -- Mutation of the caller's descriptor after registration must not leak
  -- into the sealed records.
  derived.assets.frame = "asset.mutated_frame"
  derived.contentGeometry.width = 1
  base.role = "dialogue"
  r:seal()

  local notice = assert(r:resolve("my_mod.notice"))
  Assert.equal(notice.role, "signpost", "role is inherited from the base")
  Assert.equal(notice.assets.frame, "asset.my_mod.notice_frame", "the derived asset override wins")
  Assert.equal(notice.assets.mapGraphic, "asset.my_mod.map", "unoverridden base assets are inherited")
  Assert.deepEqual(notice.contentGeometry, fullDescriptor().contentGeometry, "inherited geometry survives")
  local resolvedBase = assert(r:resolve("my_mod.base"))
  Assert.equal(resolvedBase.assets.frame, "asset.my_mod.base_frame", "the base record keeps its own frame")
  Assert.isNil(notice.base, "resolved records are flat: no live base chain")
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

return T
