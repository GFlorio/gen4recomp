// DS-shaped map/building shader. The vertex stage resolves each vertex's color
// source (literal COLOR, field-profile diffuse, or NORMAL lighting), computes
// DS lighting in camera/vector space, and forwards the resulting RGB. The pixel
// stage samples the texture, applies the exact DS MODULATE/DECAL combiner, and
// discards alpha-zero fragments for cutout draws. No fake directional light or
// second diffuse multiplication remains.
//
// The vertex-lighting algebra below (computeDsLighting, dsLightContribution,
// quantizeVectorFx, dotFxScale) is a direct GLSL transcription of
// libs/engine/src/DsLighting.lua -- see that module's header for the
// authoritative domain/truncation documentation (normals in the 1.0.9 domain
// scaled by NORMAL_FX_SCALE, light vectors in the 1.3.12 domain scaled by
// LIGHT_FX_SCALE, colors as 5-bit (0..31) integers, and every intermediate
// step truncated toward -infinity via floor() the same way melonDS's
// CalculateLighting truncates via integer shifts). ds_lighting_test locks the
// pure-Lua reference this shader mirrors. The u_mat* uniforms carry the
// effective DS material registers, normalized c/31: the field profile's
// colors -- the HGSS field engine overrides every material's stored color
// registers with the profile -- replaced wholesale by the sampled colors of a
// playing NSBMA material clip. The renderer composes them per draw item
// (effectiveMaterialColor); a static item always receives the profile.
// Each light additionally requires the polygon's light-mask bit: the renderer
// sends the draw item's 4-bit mask decoded into u_lightMask (one 0/1 float per
// light), so a light contributes only when the profile enables it AND the
// polygon's mask admits it (GBATEK POLYGON_ATTR light mask).
//
// The pixel-stage combiner (modulateRgb6, decalRgb6, expand5to6) is the exact
// DS integer MODULATE/DECAL combiner in its native 5-bit/6-bit domain
// (map_renderer_graphics_test.lua's modulate/decal cases lock the equations
// against hand-computed values). An untextured polygon samples `vec4(1.0)`
// rather than a dedicated synthetic-texture uniform: at 5-bit quantization
// that is exactly (31,31,31,31), which expand5to6 widens to (63,63,63), the
// identity element of both combiner equations -- no separate uniform is
// needed to reach that value.
//
// The post-combiner fog pass (fogDensityAt, fogBlendColor) applies only when
// both u_fogEnabled (the global DISP3DCNT gate) and u_polygonFogEnabled (this
// draw's POLYGON_ATTR FOG_ENABLE bit, PolygonState's fogEnabled field) are
// set; the density index derives from the same dsWbufferDepth quantity the
// edge pass already reads, offset by u_fogOffset and divided into the
// table's 32 steps -- real DS depth, never an invented camera near/far
// falloff. The global gate is always sent false (MapRenderer:_sendFog) until
// a real per-area/weather fog source is wired; see docs/rendering.md.

varying vec3 v_dsColor;

#ifdef VERTEX
// VertexColor is a LÖVE built-in attribute; do not redeclare it.
attribute float VertexColorSource;
attribute vec3 VertexNormal;

uniform mat4 u_proj;
uniform mat4 u_view;
uniform mat4 u_model;
uniform mat3 u_modelNormal;
uniform bool u_billboard;
uniform vec3 u_billboardCenter;
uniform vec3 u_billboardScale;

uniform bool u_lightEnabled0;
uniform bool u_lightEnabled1;
uniform bool u_lightEnabled2;
uniform bool u_lightEnabled3;
uniform vec4 u_lightMask; // polygon light-mask bits as 0/1 floats, bit i = light i
uniform vec3 u_lightVector0;
uniform vec3 u_lightVector1;
uniform vec3 u_lightVector2;
uniform vec3 u_lightVector3;
uniform vec3 u_lightColor0;
uniform vec3 u_lightColor1;
uniform vec3 u_lightColor2;
uniform vec3 u_lightColor3;
// The effective DS material registers (normalized c/31): the field profile's
// colors, replaced by a playing NSBMA clip's sampled colors.
uniform vec3 u_matDiffuse;
uniform vec3 u_matAmbient;
uniform vec3 u_matSpecular;
uniform vec3 u_matEmission;

const vec3 VIEW_DIRECTION = vec3(0.0, 0.0, 1.0);

// DsLighting fixed-point domain scales (see module header).
const float NORMAL_FX_SCALE = 512.0;
const float LIGHT_FX_SCALE = 4096.0;
const float RGB5_MAX = 31.0;

// Round a normalized float vector into an integer fixed-point domain,
// matching DsLighting.quantizeVector (round to nearest, not truncate).
vec3 quantizeVectorFx(vec3 v, float scale)
{
  return floor(v * scale + 0.5);
}

// Dot product of two same-scale fixed-point vectors, truncated (floor,
// matching a hardware arithmetic right shift) back into that scale's domain.
float dotFxScale(vec3 a, vec3 b, float scale)
{
  return floor(dot(a, b) / scale);
}

vec3 dsLightContribution(vec3 normalFx9, vec3 lightDirection, vec3 lightColorNorm,
                          vec3 diffuse5, vec3 ambient5, vec3 specular5)
{
  vec3 lightFx12 = quantizeVectorFx(normalize(lightDirection), LIGHT_FX_SCALE);

  // Dot truncates into the normal's 1.0.9 domain (DsLighting.dotNormalLight);
  // ld is the negated, front-light-gated dot, same 0..512 domain.
  float dot9 = floor(dot(normalFx9, lightFx12) / LIGHT_FX_SCALE);
  float ld = clamp(-dot9, 0.0, NORMAL_FX_SCALE);

  // Specular is only evaluated when ld > 0 (the melonDS front-light gate).
  // H is quantized to 1.0.9, dotted with the normal the same truncating way
  // to get ndh, then truncate-squared before the cos(2a)-equivalent doubling.
  float ls = 0.0;
  if (ld > 0.0) {
    vec3 halfFx9 = quantizeVectorFx(
      normalize(-lightFx12 / LIGHT_FX_SCALE + VIEW_DIRECTION),
      NORMAL_FX_SCALE
    );
    float ndh = clamp(dotFxScale(normalFx9, halfFx9, NORMAL_FX_SCALE), 0.0, NORMAL_FX_SCALE);
    float ndhSquared = floor((ndh * ndh) / NORMAL_FX_SCALE);
    ls = clamp(2.0 * ndhSquared - NORMAL_FX_SCALE, 0.0, NORMAL_FX_SCALE);
  }

  // Each material term truncates its own product before joining the
  // (ungated) ambient term; the light color then scales that per-channel
  // sum, truncating again.
  vec3 lightColor5 = floor(lightColorNorm * RGB5_MAX + 0.5);
  vec3 diffuseTerm = floor((diffuse5 * ld) / NORMAL_FX_SCALE);
  vec3 specularTerm = floor((specular5 * ls) / NORMAL_FX_SCALE);
  vec3 termSum = ambient5 + diffuseTerm + specularTerm;
  return floor((lightColor5 * termSum) / RGB5_MAX);
}

vec3 computeDsLighting(vec3 normal)
{
  vec3 normalFx9 = quantizeVectorFx(normal, NORMAL_FX_SCALE);
  vec3 diffuse5 = floor(u_matDiffuse * RGB5_MAX + 0.5);
  vec3 ambient5 = floor(u_matAmbient * RGB5_MAX + 0.5);
  vec3 specular5 = floor(u_matSpecular * RGB5_MAX + 0.5);
  vec3 emission5 = floor(u_matEmission * RGB5_MAX + 0.5);

  // Contributions from every enabled light and the emission register sum as
  // plain integers; only the final accumulator saturates to 0..31.
  vec3 acc = emission5;

  if (u_lightEnabled0 && u_lightMask.x > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector0, u_lightColor0, diffuse5, ambient5, specular5);
  if (u_lightEnabled1 && u_lightMask.y > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector1, u_lightColor1, diffuse5, ambient5, specular5);
  if (u_lightEnabled2 && u_lightMask.z > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector2, u_lightColor2, diffuse5, ambient5, specular5);
  if (u_lightEnabled3 && u_lightMask.w > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector3, u_lightColor3, diffuse5, ambient5, specular5);

  return clamp(acc, 0.0, RGB5_MAX) / RGB5_MAX;
}

vec3 quantizeRgb5(vec3 c)
{
  return floor(c * 31.0) / 31.0;
}

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vec3 modelNormal;
  vec3 normal;
  vec4 viewPosition;
  if (u_billboard) {
    modelNormal = VertexNormal / u_billboardScale;
    vec3 viewCenter = (u_view * vec4(u_billboardCenter, 1.0)).xyz;
    viewPosition = vec4(viewCenter + vertex_position.xyz * u_billboardScale, 1.0);
    normal = normalize(modelNormal);
  } else {
    modelNormal = u_modelNormal * VertexNormal;
    viewPosition = u_view * u_model * vertex_position;
    normal = normalize(mat3(u_view) * modelNormal);
  }
  int src = int(floor(VertexColorSource + 0.5));

  if (src == 0) {
    v_dsColor = quantizeRgb5(VertexColor.rgb);
  } else if (src == 2) {
    // COLOR_DIFFUSE: the vertex color IS the effective diffuse register
    // (the field profile, or the NSBMA colors replacing it).
    v_dsColor = quantizeRgb5(u_matDiffuse);
  } else {
    v_dsColor = quantizeRgb5(computeDsLighting(normal));
  }

  // LÖVE Canvas framebuffers are Y-inverted relative to the screen, and this
  // custom projection bypasses LÖVE's compensating flip; negate clip Y so the
  // scene renders upright (and with correct winding) into the offscreen canvas.
  vec4 clip = u_proj * viewPosition;
  clip.y = -clip.y;
  return clip;
}
#endif

#ifdef PIXEL
uniform bool u_useTexture;
uniform int u_alphaMode;       // 0 opaque, 1 cutout, 2 translucent
uniform float u_alphaCutoff;
uniform float u_polygonAlpha;  // normalized 5-bit polygon alpha
uniform int u_polygonMode;     // 0 modulation/toon, 1 decal
uniform float u_polygonId;     // normalized 6-bit polygon ID (id / 255), sentinel 1.0
uniform bool u_translucentAttribute; // translucent identity, separate from polygon ID
uniform mat3 u_texMatrix;      // normalized-UV transform (NSBTA texture SRT)
uniform sampler2D MainTex;

// Fog state (see file header): the global gate, this draw's own polygon
// gate, the fog color (normalized c/31, blended in the 6-bit combiner domain
// like every other color here), the 32-entry density table (0..127), and the
// depth offset in the same 24-bit domain as dsWbufferDepth.
uniform bool u_fogEnabled;
uniform bool u_polygonFogEnabled;
uniform vec3 u_fogColor;
// The 32-entry density table packed as 8 vec4s (LOVE's Shader:send flattens
// a single 32-number Lua table into this array in order: table[1..4] ->
// u_fogTable[0], table[5..8] -> u_fogTable[1], etc.), read back out via
// fogDensityAt below.
uniform vec4 u_fogTable[8];
uniform float u_fogOffset;

// 5-bit (0-31) color component -> the combiner's 6-bit (0-63) domain
// (melonDS GPU3D_Soft.cpp color conversion): 0 stays 0, any non-zero n
// becomes 2n+1.
float expand5to6(float c5)
{
  return c5 <= 0.0 ? 0.0 : c5 * 2.0 + 1.0;
}

vec3 expand5to6v(vec3 c5)
{
  return vec3(expand5to6(c5.x), expand5to6(c5.y), expand5to6(c5.z));
}

// MODULATE, one RGB component, in the 6-bit (0-63) combiner domain.
float modulateComponent6(float texture6, float vertex6)
{
  return floor(((texture6 + 1.0) * (vertex6 + 1.0) - 1.0) / 64.0);
}

vec3 modulateRgb6(vec3 texture6, vec3 vertex6)
{
  return vec3(
    modulateComponent6(texture6.x, vertex6.x),
    modulateComponent6(texture6.y, vertex6.y),
    modulateComponent6(texture6.z, vertex6.z)
  );
}

// DECAL RGB triple, 6-bit domain: texture alpha 0 -> vertex, 31 -> texture,
// otherwise a texture-alpha-weighted interpolation. melonDS computes
// ((texture6 * textureAlpha5) + (vertex6 * (31 - textureAlpha5))) >> 5, i.e.
// a truncating divide by 32, not 31.
vec3 decalRgb6(vec3 texture6, vec3 vertex6, float textureAlpha5)
{
  if (textureAlpha5 <= 0.5) {
    return vertex6;
  }
  if (textureAlpha5 >= 30.5) {
    return texture6;
  }
  return floor((texture6 * textureAlpha5 + vertex6 * (31.0 - textureAlpha5)) / 32.0);
}

// DS W-buffer depth quantization: gl_FragCoord.w is 1/clip.w and clip.w IS the
// eye-space distance, so 1/w is the linear depth in world units. It is
// normalized against the active camera's own far clipping plane (u_depthWMax,
// sent once per frame by MapRenderer) and truncated into the 24-bit integer
// domain both DS depth-buffer modes share, stored as a float (exactly
// representable: float32's 24-bit mantissa covers the full 0..0xFFFFFF
// range). The edge shader compares this value with a strict integer-domain
// inequality, never a tolerance-scaled float heuristic.
uniform float u_depthWMax;
const float DS_DEPTH_MAX = 16777215.0; // 0xFFFFFF, the 24-bit quantized-depth domain max

float dsWbufferDepth(float linearEyeDepth)
{
  float fraction = clamp(linearEyeDepth / u_depthWMax, 0.0, 1.0);
  return floor(fraction * DS_DEPTH_MAX);
}

// Index the 32-entry fog density table, clamping out-of-range indices to
// entry 0 or 31 rather than wrapping. The table is packed 4-per-vec4 (see
// u_fogTable's declaration above).
float fogDensityAt(int index)
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

// Fog blend, 6-bit combiner domain (fogColor6/fragmentRgb6 both already
// widened like every other color in this shader).
vec3 fogBlendColor(vec3 fragmentRgb6, vec3 fogColor6, float density)
{
  return floor((fragmentRgb6 * (127.0 - density) + fogColor6 * density) / 127.0);
}

// Fog depth-index derivation: the fragment's own DS-quantized depth (the
// same value the edge pass compares), offset and divided into the table's
// 32 steps. Not yet melonDS-verified; the density table/gates it feeds are
// exact.
int fogTableIndex(float dsDepth)
{
  float steps = DS_DEPTH_MAX / 32.0;
  return int(floor((dsDepth - u_fogOffset) / steps));
}

void effect()
{
  vec2 uv = (u_texMatrix * vec3(VaryingTexCoord.xy, 1.0)).xy;
  vec4 base = u_useTexture ? Texel(MainTex, uv) : vec4(1.0);

  // Both operands enter the combiner as 5-bit components widened to the
  // 6-bit domain (expand5to6); v_dsColor already arrived
  // 5-bit-quantized from the vertex stage (quantizeRgb5).
  vec3 texture5 = floor(base.rgb * 31.0 + 0.5);
  vec3 vertex5 = floor(v_dsColor * 31.0 + 0.5);
  vec3 texture6 = expand5to6v(texture5);
  vec3 vertex6 = expand5to6v(vertex5);

  float textureAlpha5 = floor(base.a * 31.0 + 0.5);
  int polygonAlpha5 = int(floor(u_polygonAlpha * 31.0 + 0.5));

  vec3 outRgb6;
  int outputAlpha5;
  if (u_polygonMode == 1) {
    // DECAL: polygon alpha unconditionally; RGB blended by texture alpha.
    outRgb6 = decalRgb6(texture6, vertex6, textureAlpha5);
    outputAlpha5 = polygonAlpha5;
  } else {
    // MODULATE: exact DS integer-domain equations.
    outRgb6 = modulateRgb6(texture6, vertex6);
    outputAlpha5 = int(floor(float((int(textureAlpha5) + 1) * (polygonAlpha5 + 1) - 1) / 32.0));
  }
  float dsDepth = dsWbufferDepth(1.0 / gl_FragCoord.w);

  // Post-combiner fog: both the global and per-polygon gates must be set,
  // matching GBATEK's two-gate fog rule.
  if (u_fogEnabled && u_polygonFogEnabled) {
    float density = fogDensityAt(fogTableIndex(dsDepth));
    vec3 fogColor6 = expand5to6v(floor(u_fogColor * 31.0 + 0.5));
    outRgb6 = fogBlendColor(outRgb6, fogColor6, density);
  }

  vec3 outRgb = outRgb6 / 63.0;
  float alpha = float(outputAlpha5) / 31.0;

  if (u_alphaMode == 1 && alpha < u_alphaCutoff) {
    discard;
  }

  love_Canvases[0] = vec4(outRgb, alpha);
  // Red: normalized polygon ID (the fragment's own real ID -- translucent
  // fragments included, never a sentinel). Green: DS-quantized W-buffer depth (see
  // dsWbufferDepth above); perspective window Z is too crushed at this
  // near/far to resolve short-object silhouettes, hence the linear domain.
  // Blue: the translucent-attribute flag, a separate logical field from the
  // polygon ID (never an invented sentinel carved out of the ID domain).
  love_Canvases[1] = vec4(u_polygonId, dsDepth, u_translucentAttribute ? 1.0 : 0.0, 1.0);
}
#endif
