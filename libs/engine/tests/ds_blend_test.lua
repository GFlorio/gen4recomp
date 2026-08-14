-- Tests for the DS translucent-blend reference: RGB blend equation,
-- destination-alpha result, same-polygon-ID self-blend rejection, and the
-- opaque/translucent depth-write interaction composed by resolveFragment.

local Assert = require("tests.support.Assert")
local DsBlend = require("libs.engine.src.DsBlend")

local T = {}

function T.blend_rgb_full_src_alpha_is_source_color()
  Assert.deepEqual(DsBlend.blendRgb6({ 63, 0, 20 }, 31, { 0, 63, 40 }), { 63, 0, 20 })
end

function T.blend_rgb_zero_src_alpha_is_dest_color()
  Assert.deepEqual(DsBlend.blendRgb6({ 63, 0, 20 }, 0, { 0, 63, 40 }), { 0, 63, 40 })
end

function T.blend_rgb_exhaustive_matches_formula()
  local src = { 60, 10, 30 }
  local dst = { 5, 50, 25 }
  for a = 0, 31 do
    local expected = {}
    for i = 1, 3 do
      expected[i] = math.floor((src[i] * a + dst[i] * (31 - a)) / 31)
    end
    Assert.deepEqual(DsBlend.blendRgb6(src, a, dst), expected, "a=" .. a)
  end
end

function T.blend_alpha_is_the_max_of_source_and_destination_exhaustive()
  for src = 0, 31 do
    for dst = 0, 31 do
      Assert.equal(DsBlend.blendAlpha5(src, dst), math.max(src, dst), "src=" .. src .. " dst=" .. dst)
    end
  end
end

function T.rejects_self_blend_when_polygon_id_matches_last_translucent()
  Assert.isTrue(DsBlend.rejectsSelfBlend(5, 5))
  Assert.isFalse(DsBlend.rejectsSelfBlend(5, 6))
end

function T.rejects_self_blend_with_no_prior_translucent_write_is_false()
  Assert.isFalse(DsBlend.rejectsSelfBlend(5, nil))
end

function T.write_depth_opaque_always_writes()
  Assert.isTrue(DsBlend.shouldWriteDepth(true, false))
  Assert.isTrue(DsBlend.shouldWriteDepth(true, true))
end

function T.write_depth_translucent_follows_the_polygon_attribute()
  Assert.isFalse(DsBlend.shouldWriteDepth(false, false))
  Assert.isTrue(DsBlend.shouldWriteDepth(false, true))
end

-- resolveFragment composes the rules above for one translucent fragment: an
-- opaque pixel only test, a translucent-over-opaque blend, translucent depth
-- write on/off, two neighboring opaque IDs under translucent coverage, the
-- rear plane, and wireframe -- the scenarios Story 9's own test list names.

function T.resolve_opaque_pixel_always_blends_fully_and_writes_depth()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 40, 40, 40 },
    srcAlpha5 = 31,
    polygonId = 1,
    isOpaque = true,
    translucentDepthWriteEnabled = false,
    dstRgb6 = { 0, 0, 0 },
    dstAlpha5 = 0,
    lastTranslucentPolygonId = nil,
  })
  Assert.deepEqual(result.rgb6, { 40, 40, 40 })
  Assert.equal(result.alpha5, 31)
  Assert.isTrue(result.writeDepth)
  Assert.isNil(result.translucentPolygonId)
end

function T.resolve_translucent_over_opaque_blends_and_tracks_polygon_id()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 63, 0, 0 },
    srcAlpha5 = 15,
    polygonId = 7,
    isOpaque = false,
    translucentDepthWriteEnabled = false,
    dstRgb6 = { 0, 63, 0 },
    dstAlpha5 = 31,
    lastTranslucentPolygonId = nil,
  })
  Assert.deepEqual(result.rgb6, DsBlend.blendRgb6({ 63, 0, 0 }, 15, { 0, 63, 0 }))
  Assert.equal(result.alpha5, 31)
  Assert.equal(result.translucentPolygonId, 7)
end

function T.resolve_translucent_over_opaque_depth_write_off_does_not_write_depth()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 30, 30, 30 },
    srcAlpha5 = 20,
    polygonId = 2,
    isOpaque = false,
    translucentDepthWriteEnabled = false,
    dstRgb6 = { 10, 10, 10 },
    dstAlpha5 = 31,
    lastTranslucentPolygonId = nil,
  })
  Assert.isFalse(result.writeDepth)
end

function T.resolve_translucent_over_opaque_depth_write_on_writes_depth()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 30, 30, 30 },
    srcAlpha5 = 20,
    polygonId = 2,
    isOpaque = false,
    translucentDepthWriteEnabled = true,
    dstRgb6 = { 10, 10, 10 },
    dstAlpha5 = 31,
    lastTranslucentPolygonId = nil,
  })
  Assert.isTrue(result.writeDepth)
end

-- Two neighboring opaque IDs under translucent coverage: the translucent
-- fragment blends over each independently -- polygonId of the opaque
-- destination has no bearing on self-blend rejection, only the translucent
-- polygon's own ID against the *previous translucent* write does.
function T.resolve_translucent_over_two_different_opaque_ids_both_blend()
  local base = {
    srcRgb6 = { 63, 63, 0 },
    srcAlpha5 = 10,
    polygonId = 9,
    isOpaque = false,
    translucentDepthWriteEnabled = false,
    lastTranslucentPolygonId = nil,
  }
  local overFirstOpaque =
    DsBlend.resolveFragment(setmetatable({ dstRgb6 = { 5, 5, 5 }, dstAlpha5 = 31 }, { __index = base }))
  local overSecondOpaque =
    DsBlend.resolveFragment(setmetatable({ dstRgb6 = { 50, 5, 5 }, dstAlpha5 = 31 }, { __index = base }))
  Assert.deepEqual(overFirstOpaque.rgb6, DsBlend.blendRgb6(base.srcRgb6, base.srcAlpha5, { 5, 5, 5 }))
  Assert.deepEqual(overSecondOpaque.rgb6, DsBlend.blendRgb6(base.srcRgb6, base.srcAlpha5, { 50, 5, 5 }))
end

-- Self-blend rejection: a second translucent fragment sharing the first's
-- polygon ID leaves the destination unchanged (no color/alpha write) but
-- still participates in the depth-write policy like any other translucent
-- fragment.
function T.resolve_rejects_self_blend_leaves_destination_unchanged()
  local dst = { rgb6 = { 12, 34, 56 }, alpha5 = 31 }
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 63, 63, 63 },
    srcAlpha5 = 20,
    polygonId = 3,
    isOpaque = false,
    translucentDepthWriteEnabled = true,
    dstRgb6 = dst.rgb6,
    dstAlpha5 = dst.alpha5,
    lastTranslucentPolygonId = 3,
  })
  Assert.deepEqual(result.rgb6, dst.rgb6)
  Assert.equal(result.alpha5, dst.alpha5)
  Assert.equal(result.translucentPolygonId, 3)
end

-- The rear plane (the field's clear/background draw) is opaque and carries
-- its own polygon ID; nothing about resolveFragment special-cases it beyond
-- ordinary opaque handling.
function T.resolve_rear_plane_is_ordinary_opaque_write()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 20, 20, 20 },
    srcAlpha5 = 31,
    polygonId = 63,
    isOpaque = true,
    translucentDepthWriteEnabled = false,
    dstRgb6 = { 0, 0, 0 },
    dstAlpha5 = 0,
    lastTranslucentPolygonId = 5,
  })
  Assert.deepEqual(result.rgb6, { 20, 20, 20 })
  Assert.isTrue(result.writeDepth)
  Assert.isNil(result.translucentPolygonId)
end

-- Wireframe polygons are opaque-mode draws (GBATEK: edge marking applies to
-- opaque polygons including wireframes); resolveFragment treats them as
-- ordinary opaque fragments, not a translucent variant.
function T.resolve_wireframe_polygon_is_opaque_not_translucent()
  local result = DsBlend.resolveFragment({
    srcRgb6 = { 5, 5, 5 },
    srcAlpha5 = 31,
    polygonId = 1,
    isOpaque = true,
    translucentDepthWriteEnabled = false,
    dstRgb6 = { 0, 0, 0 },
    dstAlpha5 = 0,
    lastTranslucentPolygonId = nil,
  })
  Assert.isNil(result.translucentPolygonId)
  Assert.isTrue(result.writeDepth)
end

return { tests = T }
