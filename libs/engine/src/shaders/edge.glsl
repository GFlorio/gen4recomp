// DS final composite pass, run as a full-screen pass over the finalState
// target written by map.glsl (red edge polygon ID, green DS-quantized depth,
// blue per-polygon fog gate, alpha validity). It performs, in order, edge
// marking (replacing scene RGB outright when a pixel is a marked silhouette)
// and then fog (blending the -- possibly edge-replaced -- color against the
// scene's global weather fog), matching GBATEK's "3D Display" ordering: edge
// marking first, fog over the whole composited result second.
//
// GBATEK ("4000330h..33Fh - EDGE_COLOR") defines the edge rule: a pixel is
// marked when at least one of its four surrounding pixels (up, down, left,
// right -- no diagonals) has a different polygon ID *and* the marked pixel's
// depth is strictly less than that neighbour's, i.e. the marked pixel is in
// front. The depth condition is what suppresses coplanar boundaries: adjacent
// ground batches and flat shadow decals carry different polygon IDs but no
// depth step, so they are never marked. The edge color is chosen by the
// marked pixel's own ID, indexed as id >> 3. The depth comparison is a strict
// integer-domain inequality, never a tolerance-scaled float heuristic.
//
// The green channel holds the DS-quantized W-buffer depth map.glsl computes
// (see its dsWbufferDepth) rather than raw window Z: a perspective near/far of
// 0.1/400 crushes window Z to ~0.993 across the whole field, so silhouette
// steps for anything but very close geometry would fall below any usable
// threshold and go unmarked. The DS depth test works in W-buffer (linear)
// space, where a fixed world gap is detectable at any range; matching that is
// what makes short objects (signposts, hydrants) outline as they do on
// hardware. Fog's depth input is this same camera.far-normalized proxy, not
// an exact reproduction of the DS's own per-polygon W-buffer normalization
// (see dsWbufferDepth's header and docs/rendering.md); the density/blend
// arithmetic below is the exact melonDS sequencing, applied to that
// approximate depth.
//
// Only opaque geometry participates in edge marking -- "Edge Marking is
// applied ONLY to opaque polygons (including wire-frames)". Translucent draws
// leave finalState untouched (MapRenderer's translucent pass binds a
// narrower target set that omits it), so this pass never observes a
// translucent fragment's own id/depth/fog gate.
//
// Hardware marks a single 256x192 pixel. u_edgeRadius rescales that to the
// current framebuffer so the outline keeps its DS-relative weight.
//
// Edge compositing replaces scene RGB outright (hardware behavior) rather than
// alpha-mixing with it; there is no alpha-mix uniform on this path.
//
// Fog (melonDS src/GPU3D_Soft.cpp, SoftRenderer3D::CalculateFogDensity and the
// post-density blend in SoftRenderer3D::RenderPixel; see tests/support/DsFog.lua
// for the independently hand-verified pure-Lua transcription this mirrors):
// both the global gate (u_fogEnabled, DISP3DCNT) and this pixel's own
// per-polygon gate (finalState's blue channel, POLYGON_ATTR FOG_ENABLE) must
// be set. The density index derives from the depth (offset by
// u_fogOffsetDepth, already converted from the raw G3X FOG_OFFSET register by
// MapRenderer -- *0x200 -- once per frame, not per pixel), shifted by the
// preset's slope (u_fogShift), and interpolated across the 32-entry density
// table with both endpoints duplicated. RGB blends in the 6-bit combiner
// domain (fogColor6/fragmentRgb6) with a truncating divide by 128 (density
// is 0..128, not 0..127). Alpha blends the same way, in the 5-bit domain
// (u_fogAlpha against the source alpha quantized to 5 bits) -- this draw's
// output alpha is real data consumed verbatim by MapRenderer's "replace"/
// "premultiplied" composite blend, not by the host's default alpha
// compositing (see MapRenderer.lua's doDraw for why that blend mode is
// required once this alpha is meaningful).

#ifdef PIXEL
uniform Image u_idTex;
uniform vec2 u_texelSize;
uniform vec3 u_edgeColors[8];
uniform int u_edgeRadius;

const int MAX_EDGE_RADIUS = 8;

// HGSS's real clear/rear-plane polygon ID and the domain maximum every real
// draw's u_polygonId is normalized by (MapRenderer.CLEAR_POLYGON_ID; see
// MapRenderer.lua). Named so the encode (Lua) and decode (here) sides cannot
// silently drift apart.
const float CLEAR_POLYGON_ID = 63.0;

bool marked(vec2 uv, vec2 offset, float centerId, float centerDepth)
{
  vec3 neighborSample = Texel(u_idTex, uv + offset).rgb;
  bool differentId = abs(neighborSample.r - centerId) > 0.5 / CLEAR_POLYGON_ID;
  // Strictly less, no tolerance -- the marked pixel must be in front.
  bool centerInFront = centerDepth < neighborSample.g;
  return differentId && centerInFront;
}

// Fog state (see file header): the global gate, the fog color (normalized
// c/31, widened to the 6-bit combiner domain like every other color), the
// 32-entry density table (raw bytes, 0..255), the depth offset already
// converted into the same domain as finalState's depth channel, and the
// preset's slope (used directly as the density shift exponent).
uniform bool u_fogEnabled;
uniform vec3 u_fogColor;
// The 32-entry density table packed as 8 vec4s (LOVE's Shader:send flattens
// a single 32-number Lua table into this array in order: table[1..4] ->
// u_fogTable[0], table[5..8] -> u_fogTable[1], etc.), read back out via
// fogTableEntry below.
uniform vec4 u_fogTable[8];
uniform float u_fogOffsetDepth;
uniform float u_fogShift;
uniform float u_fogAlpha;

// melonDS CalculateFogDensity's numeric domain (SoftRenderer3D, GPU3D_Soft.cpp).
const float FOG_DEPTH_QUANTUM = 4.0;      // (z >> 2) before applying fogShift
const float FOG_INTERVAL_SPAN = 131072.0; // 0x20000: one density-table interval's width, and the interpolation-fraction domain
const float FOG_TABLE_LAST_ID = 32.0;     // out-of-range densityId clamps here (densityFrac forced to 0)
const float FOG_DENSITY_SATURATE = 127.0; // raw density >= this saturates to FOG_BLEND_DOMAIN
const float FOG_BLEND_DOMAIN = 128.0;     // density's own domain (0..128) and the blend equations' divisor

// 5-bit (0-31) color component -> the combiner's 6-bit (0-63) domain
// (melonDS GPU3D_Soft.cpp color conversion): 0 stays 0, any non-zero n
// becomes 2n+1. Mirrors map.glsl's expand5to6/expand5to6v exactly; duplicated
// here rather than shared because GLSL has no cross-shader-source include.
float expand5to6(float c5)
{
  return c5 <= 0.0 ? 0.0 : c5 * 2.0 + 1.0;
}

vec3 expand5to6v(vec3 c5)
{
  return vec3(expand5to6(c5.x), expand5to6(c5.y), expand5to6(c5.z));
}

// Index the 32-entry fog density table, duplicating both endpoints: indices
// <=0 and >=33 both collapse to entry 0/31 respectively, which is exactly the
// "expanded" 34-entry table CalculateFogDensity interpolates against (see
// tests/support/DsFog.lua's expandedEntry, the pure-Lua reference this
// mirrors) -- the raw table is 32 entries, but the interpolation lookup is
// always evaluated in the 34-entry duplicated-endpoint domain.
float fogTableEntry(int index)
{
  int clamped = index;
  if (clamped < 0) {
    clamped = 0;
  } else if (clamped > 31) {
    clamped = 31;
  }
  vec4 group = u_fogTable[clamped / 4];
  int component = clamped - (clamped / 4) * 4;
  if (component == 0) {
    return group.x;
  } else if (component == 1) {
    return group.y;
  } else if (component == 2) {
    return group.z;
  }
  return group.w;
}

// SoftRenderer3D::CalculateFogDensity's exact integer sequencing, evaluated
// in floats (every intermediate is an exact integer within float32's 24-bit
// mantissa for this pipeline's depth/table domains).
float fogDensity(float depthValue)
{
  float fogDensityId;
  float fogDensityFraction;
  if (depthValue < u_fogOffsetDepth) {
    fogDensityId = 0.0;
    fogDensityFraction = 0.0;
  } else {
    float shifted = floor((depthValue - u_fogOffsetDepth) / FOG_DEPTH_QUANTUM) * pow(2.0, u_fogShift);
    fogDensityId = floor(shifted / FOG_INTERVAL_SPAN);
    if (fogDensityId >= FOG_TABLE_LAST_ID) {
      fogDensityId = FOG_TABLE_LAST_ID;
      fogDensityFraction = 0.0;
    } else {
      fogDensityFraction = shifted - fogDensityId * FOG_INTERVAL_SPAN;
    }
  }
  int fogDensityIdInt = int(fogDensityId);
  float lo = fogTableEntry(fogDensityIdInt);
  float hi = fogTableEntry(fogDensityIdInt + 1);
  float density = floor((lo * (FOG_INTERVAL_SPAN - fogDensityFraction) + hi * fogDensityFraction) / FOG_INTERVAL_SPAN);
  if (density >= FOG_DENSITY_SATURATE) {
    density = FOG_BLEND_DOMAIN;
  }
  return density;
}

// One RGB component's fog blend (6-bit combiner domain),
// SoftRenderer3D::RenderPixel's post-density step: a truncating divide by
// 128 (density is 0..128), not 127.
float fogBlendComponent(float component, float fogComponent, float density)
{
  return floor((fogComponent * density + component * (FOG_BLEND_DOMAIN - density)) / FOG_BLEND_DOMAIN);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
{
  vec4 scene = Texel(tex, uv);
  vec3 center = Texel(u_idTex, uv).rgb;
  float centerId = center.r;
  float centerDepth = center.g;
  float centerFogGate = center.b;
  int centerPolygonId = int(floor(centerId * CLEAR_POLYGON_ID + 0.5));

  vec4 outColor = scene;

  // Every legitimately encoded id (real draws and the clear/rear-plane entry
  // alike) decodes into 0..63; this is a cheap defensive guard against
  // malformed upstream data, not a sentinel check -- well-formed input can
  // never reach it. Malformed data skips both edge marking and fog.
  if (centerPolygonId <= int(CLEAR_POLYGON_ID)) {
    bool edge = false;
    for (int i = 1; i <= MAX_EDGE_RADIUS; i++) {
      if (i > u_edgeRadius) break;
      float step = float(i);
      vec2 dx = vec2(u_texelSize.x * step, 0.0);
      vec2 dy = vec2(0.0, u_texelSize.y * step);
      if (marked(uv, dx, centerId, centerDepth)
        || marked(uv, -dx, centerId, centerDepth)
        || marked(uv, dy, centerId, centerDepth)
        || marked(uv, -dy, centerId, centerDepth)) {
        edge = true;
        break;
      }
    }

    if (edge) {
      vec3 edgeColor = u_edgeColors[centerPolygonId / 8];
      // DS hardware edge compositing replaces RGB outright; it does not
      // alpha-mix with the scene color.
      outColor = vec4(edgeColor, scene.a);
    }

    // Post-edge fog: both the global and per-polygon gates must be set,
    // matching GBATEK's two-gate fog rule. Reads whatever outColor edge
    // marking left behind -- fog composites on top of the edge-replaced
    // color, never the pre-edge scene color. Alpha blends the same way as
    // RGB, in the 5-bit domain (melonDS's RenderPixel); the source alpha is
    // quantized to 5 bits before the blend, matching the DS's own alpha
    // precision at this stage. See MapRenderer.lua's doDraw for why this
    // draw's blend mode must be "replace"/"premultiplied" once this alpha is
    // meaningful data rather than an always-1.0 pass-through.
    if (u_fogEnabled && centerFogGate > 0.5) {
      float density = fogDensity(centerDepth);
      vec3 fogColor6 = expand5to6v(floor(u_fogColor * 31.0 + 0.5));
      vec3 outRgb6 = floor(outColor.rgb * 63.0 + 0.5);
      vec3 blendedRgb6 = vec3(
        fogBlendComponent(outRgb6.x, fogColor6.x, density),
        fogBlendComponent(outRgb6.y, fogColor6.y, density),
        fogBlendComponent(outRgb6.z, fogColor6.z, density)
      );
      outColor.rgb = blendedRgb6 / 63.0;

      float srcAlpha5 = floor(outColor.a * 31.0 + 0.5);
      float blendedAlpha5 = fogBlendComponent(srcAlpha5, u_fogAlpha, density);
      outColor.a = blendedAlpha5 / 31.0;
    }
  }

  return outColor;
}
#endif
