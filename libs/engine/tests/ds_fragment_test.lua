-- Tests for the DS fragment-combiner reference: MODULATE and DECAL RGB/alpha
-- equations in their native integer domains, the 5-bit -> 6-bit color
-- widening, and the synthetic untextured-polygon texture value.

local Assert = require("tests.support.Assert")
local DsFragment = require("libs.engine.src.DsFragment")

local T = {}

function T.expand5to6_boundaries()
  Assert.equal(DsFragment.expand5to6(0), 0)
  Assert.equal(DsFragment.expand5to6(31), 63)
end

function T.expand5to6_exhaustive_matches_bit_replication()
  for c5 = 0, 31 do
    local expected = c5 * 2 + math.floor(c5 / 16)
    Assert.equal(DsFragment.expand5to6(c5), expected, "c5=" .. c5)
  end
end

function T.modulate_component_identity_at_full_white_texture()
  -- A fully white (63) texture leaves the vertex component unchanged: the
  -- synthetic untextured value must have this property, or untextured
  -- MODULATE polygons would visibly tint.
  for v6 = 0, 63 do
    Assert.equal(DsFragment.modulateComponent6(63, v6), v6, "v6=" .. v6)
  end
end

function T.modulate_component_identity_at_full_white_vertex()
  for t6 = 0, 63 do
    Assert.equal(DsFragment.modulateComponent6(t6, 63), t6, "t6=" .. t6)
  end
end

function T.modulate_component_zero_at_either_zero_input()
  for v6 = 0, 63, 7 do
    Assert.equal(DsFragment.modulateComponent6(0, v6), 0, "v6=" .. v6)
  end
  for t6 = 0, 63, 7 do
    Assert.equal(DsFragment.modulateComponent6(t6, 0), 0, "t6=" .. t6)
  end
end

function T.modulate_component_exhaustive_matches_formula()
  for t6 = 0, 63 do
    for v6 = 0, 63 do
      local expected = math.floor(((t6 + 1) * (v6 + 1) - 1) / 64)
      Assert.equal(DsFragment.modulateComponent6(t6, v6), expected)
    end
  end
end

function T.modulate_alpha_identity_and_zero_boundaries()
  Assert.equal(DsFragment.modulateAlpha5(31, 31), 31)
  Assert.equal(DsFragment.modulateAlpha5(0, 31), 0)
  Assert.equal(DsFragment.modulateAlpha5(31, 0), 0)
  Assert.equal(DsFragment.modulateAlpha5(0, 0), 0)
end

function T.modulate_alpha_exhaustive_matches_formula()
  for at = 0, 31 do
    for ap = 0, 31 do
      local expected = math.floor(((at + 1) * (ap + 1) - 1) / 32)
      Assert.equal(DsFragment.modulateAlpha5(at, ap), expected, "at=" .. at .. " ap=" .. ap)
    end
  end
end

function T.decal_alpha_ignores_texture_alpha_and_equals_polygon_alpha()
  for ap = 0, 31 do
    Assert.equal(DsFragment.decalAlpha5(ap), ap)
  end
end

function T.decal_rgb_texture_alpha_zero_is_vertex_rgb()
  local vertex = { 10, 20, 30 }
  local texture = { 63, 0, 5 }
  Assert.deepEqual(DsFragment.decalRgb6(texture, vertex, 0), vertex)
end

function T.decal_rgb_texture_alpha_31_is_texture_rgb()
  local vertex = { 10, 20, 30 }
  local texture = { 63, 0, 5 }
  Assert.deepEqual(DsFragment.decalRgb6(texture, vertex, 31), texture)
end

function T.decal_rgb_interpolates_by_texture_alpha_exhaustive()
  local vertex = { 0, 63, 20 }
  local texture = { 63, 0, 50 }
  for ta = 0, 31 do
    local expected = {}
    for i = 1, 3 do
      expected[i] = vertex[i] + math.floor((texture[i] - vertex[i]) * ta / 31)
    end
    Assert.deepEqual(DsFragment.decalRgb6(texture, vertex, ta), expected, "ta=" .. ta)
  end
end

function T.synthetic_texture_is_full_white_opaque_not_normalized_one()
  local rgb6, alpha5 = DsFragment.syntheticTexture()
  Assert.deepEqual(rgb6, { 63, 63, 63 })
  Assert.equal(alpha5, 31)
end

function T.untextured_modulate_polygon_passes_vertex_color_unchanged()
  local rgb6, alpha5 = DsFragment.syntheticTexture()
  local vertex = { 5, 40, 63 }
  local out = {
    DsFragment.modulateComponent6(rgb6[1], vertex[1]),
    DsFragment.modulateComponent6(rgb6[2], vertex[2]),
    DsFragment.modulateComponent6(rgb6[3], vertex[3]),
  }
  Assert.deepEqual(out, vertex)
  Assert.equal(DsFragment.modulateAlpha5(alpha5, 17), 17)
end

function T.untextured_decal_polygon_renders_opaque_white()
  local rgb6, alpha5 = DsFragment.syntheticTexture()
  local vertex = { 5, 40, 63 }
  Assert.deepEqual(DsFragment.decalRgb6(rgb6, vertex, alpha5), rgb6)
end

return { tests = T }
