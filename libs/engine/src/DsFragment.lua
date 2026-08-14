-- Pure Lua reference for the DS GPU3D pixel combiner: MODULATE and DECAL
-- texture/vertex blending in their native integer domains. This is the
-- executable specification the map fragment shader (shaders/map.glsl) is
-- transcribed from; no love dependency, arithmetic only.
--
-- Authoritative source: GBATEK "Texture Blending" / "3D Textures". The
-- combiner does not operate on the vertex engine's native 5-bit (0-31) RGB
-- domain: both the decoded texel and the interpolated vertex color are first
-- widened to a 6-bit (0-63) domain (bit-replication: c6 = c5*2 + (c5>>4), so
-- 31 -> 63 and 0 -> 0), and MODULATE combines in that 6-bit domain:
--   Final = ((Texture6 + 1) * (Vertex6 + 1) - 1) >> 6
-- Alpha stays 5-bit (0-31) throughout -- there is no widened alpha domain:
--   Final_Alpha = ((TexAlpha5 + 1) * (PolyAlpha5 + 1) - 1) >> 5
-- DECAL keeps the polygon alpha unconditionally and blends RGB by the
-- texture's own alpha: texture alpha 0 yields the vertex color untouched,
-- texture alpha 31 yields the texture color untouched, and any value between
-- linearly interpolates (truncating divide by 31, the alpha full scale).
--
-- Untextured polygons (TEXIMAGE_PARAM format 0) do not fall back to a
-- normalized vec4(1.0): they substitute the exact synthetic texture value
-- (63,63,63,31) in this module's native domain. That value is the identity
-- element of both combiner equations above (proven by
-- modulate_component_identity_at_full_white_texture and
-- untextured_decal_polygon_renders_opaque_white in ds_fragment_test.lua), so
-- an untextured MODULATE polygon reproduces its vertex color exactly and an
-- untextured DECAL polygon renders opaque white -- not an accidental
-- normalized-float coincidence.

local DsFragment = {}

-- 5-bit (0-31) color component -> the combiner's 6-bit (0-63) domain, by
-- hardware bit-replication of the top bit into the new low bit.
function DsFragment.expand5to6(c5)
  assert(c5 == math.floor(c5) and c5 >= 0 and c5 <= 31, "expand5to6 expects a 5-bit component")
  return c5 * 2 + math.floor(c5 / 16)
end

-- MODULATE, one RGB component, in the 6-bit (0-63) combiner domain.
function DsFragment.modulateComponent6(texture6, vertex6)
  return math.floor(((texture6 + 1) * (vertex6 + 1) - 1) / 64)
end

-- MODULATE RGB triple; texture6/vertex6 are {r, g, b} in 0-63.
function DsFragment.modulateRgb6(texture6, vertex6)
  return {
    DsFragment.modulateComponent6(texture6[1], vertex6[1]),
    DsFragment.modulateComponent6(texture6[2], vertex6[2]),
    DsFragment.modulateComponent6(texture6[3], vertex6[3]),
  }
end

-- MODULATE alpha, 5-bit (0-31) domain.
function DsFragment.modulateAlpha5(textureAlpha5, polygonAlpha5)
  return math.floor(((textureAlpha5 + 1) * (polygonAlpha5 + 1) - 1) / 32)
end

-- DECAL alpha: the polygon alpha unconditionally, regardless of texture alpha.
function DsFragment.decalAlpha5(polygonAlpha5)
  return polygonAlpha5
end

-- DECAL RGB triple, 6-bit domain: texture alpha 0 -> vertex, 31 -> texture,
-- otherwise a texture-alpha-weighted interpolation (truncating divide by the
-- alpha full scale, 31).
function DsFragment.decalRgb6(texture6, vertex6, textureAlpha5)
  if textureAlpha5 == 0 then
    return { vertex6[1], vertex6[2], vertex6[3] }
  end
  if textureAlpha5 == 31 then
    return { texture6[1], texture6[2], texture6[3] }
  end
  local out = {}
  for i = 1, 3 do
    out[i] = vertex6[i] + math.floor((texture6[i] - vertex6[i]) * textureAlpha5 / 31)
  end
  return out
end

-- The exact synthetic texture value used for every untextured polygon mode:
-- opaque white in the combiner's native domain (rgb6 = {63,63,63}, alpha5 =
-- 31), not a normalized vec4(1.0). Returns rgb6, alpha5.
function DsFragment.syntheticTexture()
  return { 63, 63, 63 }, 31
end

return DsFragment
