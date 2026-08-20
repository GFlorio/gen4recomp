// DS final composite pass, run over the world raster before its nearest
// upscale to presentation resolution.
// sceneColor target (map.glsl's color-only output) and the same-resolution
// renderState target (state.glsl's state output: red edge polygon ID, green
// DS-quantized depth, blue per-polygon fog gate, alpha last-translucent-ID
// encoding). It resolves each pixel through explicit fogged candidates:
// scene candidate -> fog(scene) and, when marked, edge candidate
// vec4(edgeColorFor(id), scene.a) -> fog(edge candidate), then the project's
// current antialias approximation (50% mix of the two fogged candidates when
// u_antialiasEnabled). Fog is therefore applied per candidate before any
// mix, so fog alpha is also resolved before the AA interpolation.
//
// Both candidates share the center pixel's single depth and fog gate. A future
// exact DS path would fog distinct top and lower buffers with their own depth
// and fog state before coverage; this pass has only one depth/fog state and
// cannot model that distinction, so the limitation is documented rather than
// hidden. State A (last translucent ID) is not consumed by edge or fog.
//
// The color and state targets have identical dimensions and identical
// screen-space coverage (see MapRenderer:_ensureTargets): state
// classification is never downsampled, so a visible one-host-pixel state
// change has a matching one-host-pixel state location. The state texture is
// nearest-filtered; every sample snaps/clamps to a render-state pixel center
// explicitly rather than relying on the sampler's own filtering/clamp
// behavior. The neighbor probes sample at a distance of u_edgeRadiusPx
// integer render-state pixels -- the rounded field logical pixel scale
// (referenceFrame.height / 192 * camera zoom, minimum 1; see
// FieldViewport:logicalPixelScale and MapRenderer:draw) -- so DS-relative
// edge width is a sampling distance over the world-raster state, not a
// block of host pixels owned by one coarse state texel.
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
// The green channel holds the DS Z-buffer depth state.glsl computes (see its
// dsZbufferDepth) rather than raw window Z: the DS 24-bit Z domain preserves
// depth separation across the whole field far better than a raw 24-bit
// window-Z quantization would, so silhouette steps for short field objects
// stay well above any usable threshold and mark as they do on hardware. The
// DS field camera selects GX_BUFFERMODE_Z (HGSS Camera_ApplyPerspectiveType;
// see state.glsl's header), so the depth is the DS Z-buffer conversion of
// the host fragment's normalized window depth, evaluated exactly per the
// pinned melonDS formula (windowZ -> ndcZ = 2*windowZ - 1, ndcZ scaled by
// 0x4000 with truncation toward zero, +0x3FFF, *0x200, clamped to
// 0..0xFFFFFF). Projection, rasterization, and interpolation remain
// host-side -- only the depth-domain conversion is exact DS (see
// docs/rendering.md). Fog's depth input is this same DS Z depth, used
// directly without any camera-far rescaling; the density/blend
// arithmetic below is the exact melonDS sequencing, applied to that depth.
//
// Only opaque geometry participates in edge marking -- "Edge Marking is
// applied ONLY to opaque polygons (including wire-frames)". Ordinary
// translucent and mixed-translucent draws never touch renderState
// (MapRenderer's state pass only draws opaque/cutout/mixed-opaque/wireframe),
// so this pass never observes a translucent fragment's own id/depth/fog gate.
//
// Edge compositing replaces scene RGB outright (hardware behavior) rather than
// alpha-mixing with it; there is no alpha-mix uniform on this path. HGSS field
// rendering additionally enables 3D antialiasing (G3X_AntiAlias(TRUE)), which
// this project approximates as 50% coverage at a marked edge
// (3DFinalPassEdgeFS.glsl); u_antialiasEnabled selects that coverage mix vs.
// the flat replacement. This 50% mix is the project's current approximation,
// not exact DS lower-pixel coverage generation.
//
// Fog (melonDS src/GPU3D_Soft.cpp, SoftRenderer3D::CalculateFogDensity and the
// post-density blend in SoftRenderer3D::RenderPixel; see tests/support/DsFog.lua
// for the independently hand-verified pure-Lua transcription this mirrors):
// both the global gate (u_fogEnabled, DISP3DCNT) and this pixel's own
// per-polygon gate (center state's blue channel, POLYGON_ATTR FOG_ENABLE) must
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
uniform Image u_renderState;
uniform vec2 u_stateSize; // the state target's actual width/height (not its reciprocal)
uniform int u_edgeRadiusPx; // integer sampling distance: the rounded field logical pixel scale, >= 1
uniform vec3 u_edgeColors[8];
uniform bool u_antialiasEnabled;

// HGSS's real clear/rear-plane polygon ID and the domain maximum every real
// draw's u_polygonId is normalized by (MapRenderer.CLEAR_POLYGON_ID; see
// MapRenderer.lua). Named so the encode (Lua) and decode (here) sides cannot
// silently drift apart.
const float CLEAR_POLYGON_ID = 63.0;

// Snap a color-space UV to the center of the render-state pixel it falls in,
// clamped to the state texture's edge, so the sample is exact -- the state
// raster shares the color raster's dimensions, so this is a one-to-one
// mapping that only ever adjusts for rasterization rounding, never for a
// resolution gap (spec: sampling may derive from the color UV but must
// snap/clamp to the render-state pixel center before the neighbor probes).
vec2 statePixelCenter(vec2 uv)
{
  vec2 clamped = clamp(uv, vec2(0.0), vec2(1.0) - 0.5 / u_stateSize);
  vec2 pixel = floor(clamped * u_stateSize);
  return (pixel + vec2(0.5)) / u_stateSize;
}

// The rear-plane state (MapRenderer.DS_STATE_CLEAR): polygon id 63 (the real
// HGSS clear/rear-plane id, not an out-of-domain sentinel), the farthest
// quantized depth (DS_DEPTH_MAX, the 24-bit maximum -- the clear/rear plane
// stays at 0xFFFFFF even though a geometry fragment at windowZ == 1 maps to
// 0xFFFE00 under the DS Z conversion), and no fog gate. Used for any state
// sample that falls outside the logical screen -- a neighbor probe past the
// screen edge must behave like the rear plane, not like a clamped copy of the
// center pixel (which would suppress a silhouette at the screen boundary).
// Only the RGB channels are read here (the edge/fog pass never samples the
// last-translucent-ID encoding in A); the clear's alpha 0 is the compositor's
// "no translucent overlay" value.
vec3 rearPlaneState()
{
  return vec3(1.0, 16777215.0, 0.0);
}

// Sample the render-state texture at a snapped, clamped pixel center. Off-
// screen samples return the rear-plane state; only in-bounds neighbor
// positions are clamped to the state texture edge (see marked below).
vec3 stateSample(vec2 uv)
{
  if (uv.x < 0.0 || uv.y < 0.0 || uv.x >= 1.0 || uv.y >= 1.0) {
    return rearPlaneState();
  }
  return Texel(u_renderState, statePixelCenter(uv)).rgb;
}

bool marked(vec2 centerUv, vec2 offset, float centerId, float centerDepth)
{
  vec3 neighborSample = stateSample(centerUv + offset);
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
// The 32-entry density table packed as 8 distinctly-named vec4s
// (u_fogTable0..u_fogTable7), one per 4-entry group. LÖVE 11.5 fills only
// the first vec4 of a `vec4[N]` array uniform when sent a flat table, so a
// single-array delivery could never reach entries past index 0; each group
// is therefore its own named uniform, sent separately (MapRenderer:_sendFog)
// and read back out via fogTableEntry below.
uniform vec4 u_fogTable0;
uniform vec4 u_fogTable1;
uniform vec4 u_fogTable2;
uniform vec4 u_fogTable3;
uniform vec4 u_fogTable4;
uniform vec4 u_fogTable5;
uniform vec4 u_fogTable6;
uniform vec4 u_fogTable7;
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
  int group = clamped / 4;
  int component = clamped - group * 4;
  vec4 value;
  if (group == 0) {
    value = u_fogTable0;
  } else if (group == 1) {
    value = u_fogTable1;
  } else if (group == 2) {
    value = u_fogTable2;
  } else if (group == 3) {
    value = u_fogTable3;
  } else if (group == 4) {
    value = u_fogTable4;
  } else if (group == 5) {
    value = u_fogTable5;
  } else if (group == 6) {
    value = u_fogTable6;
  } else {
    value = u_fogTable7;
  }
  if (component == 0) {
    return value.x;
  } else if (component == 1) {
    return value.y;
  } else if (component == 2) {
    return value.z;
  }
  return value.w;
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

// Fog a single candidate with the center state's depth and fog gate. Keeps
// the existing integer RGB6/alpha5 conversion, density interpolation,
// color-mode gate, alpha fog, and /128 arithmetic exactly -- only the
// candidate's own RGB/alpha inputs vary. Both the scene and edge candidates
// are fogged with the same center state; there is no per-candidate depth or
// per-candidate fog gate in this single-buffer approximation. State A is not
// read.
vec4 applyFog(vec4 src, float fogGate, float depth)
{
  if (!u_fogEnabled || fogGate <= 0.5) {
    return src;
  }
  float density = fogDensity(depth);
  vec3 fogColor6 = expand5to6v(floor(u_fogColor * 31.0 + 0.5));
  vec3 srcRgb6 = floor(src.rgb * 63.0 + 0.5);
  vec3 blendedRgb6 = vec3(
    fogBlendComponent(srcRgb6.x, fogColor6.x, density),
    fogBlendComponent(srcRgb6.y, fogColor6.y, density),
    fogBlendComponent(srcRgb6.z, fogColor6.z, density)
  );
  vec3 outRgb = blendedRgb6 / 63.0;
  float srcAlpha5 = floor(src.a * 31.0 + 0.5);
  float blendedAlpha5 = fogBlendComponent(srcAlpha5, u_fogAlpha, density);
  float outA = blendedAlpha5 / 31.0;
  return vec4(outRgb, outA);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
{
  vec4 scene = Texel(tex, uv);
  vec3 center = stateSample(uv);
  float centerId = center.r;
  float centerDepth = center.g;
  float centerFogGate = center.b;
  int centerPolygonId = int(floor(centerId * CLEAR_POLYGON_ID + 0.5));

  // Every legitimately encoded id (real draws and the clear/rear-plane entry
  // alike) decodes into 0..63; this is a cheap defensive guard against
  // malformed upstream data, not a sentinel check -- well-formed input can
  // never reach it. Malformed data skips both edge marking and fog.
  if (centerPolygonId > int(CLEAR_POLYGON_ID)) {
    return scene;
  }

  vec2 stateTexel = 1.0 / u_stateSize;
  float radius = float(u_edgeRadiusPx);
  vec2 dx = vec2(radius * stateTexel.x, 0.0);
  vec2 dy = vec2(0.0, radius * stateTexel.y);
  // The four orthogonal neighbor probes at one integer edge radius, never
  // diagonals. In-bounds neighbor positions clamp to the state texture
  // edge (the state sample itself snaps to the clamped pixel center);
  // probes past the logical screen edge fall back to the rear-plane state
  // in stateSample.
  bool isMarked =
    marked(uv, dx, centerId, centerDepth)
    || marked(uv, -dx, centerId, centerDepth)
    || marked(uv, dy, centerId, centerDepth)
    || marked(uv, -dy, centerId, centerDepth);

  // Candidate-based resolve: fog each candidate with the center state's
  // single depth/fog gate, then mix the fogged candidates. No-edge pixels
  // receive only the fogged scene; edge pixels with AA disabled receive the
  // fogged edge candidate; edge pixels with AA enabled receive 50% of each
  // fogged candidate. The 50% step is the project's current approximation,
  // not exact hardware lower-pixel coverage; both candidates share the
  // center depth/fog state, and fog alpha is resolved before the mix.
  vec4 sceneFogged = applyFog(scene, centerFogGate, centerDepth);
  if (!isMarked) {
    return sceneFogged;
  }
  vec3 edgeColor = u_edgeColors[centerPolygonId / 8];
  vec4 edgeCandidate = vec4(edgeColor, scene.a);
  vec4 edgeFogged = applyFog(edgeCandidate, centerFogGate, centerDepth);
  if (!u_antialiasEnabled) {
    return edgeFogged;
  }
  return mix(sceneFogged, edgeFogged, 0.5);
}
#endif
