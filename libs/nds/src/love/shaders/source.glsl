// DS-shaped translucent source-metadata shader. Rasterizes exactly one blended
// draw's partial-alpha fragments into the sourceMeta buffer for the
// compositor (composite.glsl), carrying the per-fragment state the composite
// needs to apply the exact DS equations: a valid/accepted flag, the source
// polygon's fog-enable bit, and the source polygon ID.
// The source COLOR is produced by the ordinary color shader (map.glsl) into a
// separate sourceColor buffer with the same translucent fragment pass, so the
// combiner/lighting equations are not duplicated here.
//
// The vertex stage is the same world/billboard placement map.glsl uses (see
// that shader's header and position()), including the clip-Y negation for
// LÖVE Canvas framebuffers.
//
// The pixel stage computes the same exact DS final-alpha5 map.glsl computes
// for MODULATE/DECAL (see map.glsl's outputAlpha5), applies the same
// translucent/mixed-translucent discard predicate, and then applies the DS
// same-ID rejection: a fragment whose polygon ID equals the active
// destination's last-translucent-ID encoding (state A) is rejected completely
// -- before any depth write -- so a rejected fragment can never poison later
// depth tests. Accepted fragments write:
//   sourceMeta: R = valid flag 1.0 (0.0 = no source fragment at this pixel)
//               G = 0.0 (reserved; translucent source does not write depth)
//               B = the source polygon's fog-enable bit
//               A = (source polygon ID + 1) / 64. This encoding round-trips
//                   every 6-bit ID through normalized rgba8 storage.
//
// The depth test against the current opaque host depth attachment happens in
// the ordinary rasterizer; source fragments never write that depth buffer.

varying vec2 v_sourceUv;

#ifdef VERTEX
attribute vec3 VertexNormal; // present in the shared vertex layout, unused here

uniform mat4 u_proj;
uniform mat4 u_view;
uniform mat4 u_model;
uniform bool u_billboard;
uniform vec3 u_billboardCenter;
uniform vec3 u_billboardScale;
uniform mat3 u_texMatrix;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vec4 viewPosition;
  if (u_billboard) {
    vec3 viewCenter = (u_view * vec4(u_billboardCenter, 1.0)).xyz;
    viewPosition = vec4(viewCenter + vertex_position.xyz * u_billboardScale, 1.0);
  } else {
    viewPosition = u_view * u_model * vertex_position;
  }

  v_sourceUv = (u_texMatrix * vec3(VertexTexCoord.xy, 1.0)).xy;

  vec4 clip = u_proj * viewPosition;
  clip.y = -clip.y;
  return clip;
}
#endif

#ifdef PIXEL
uniform bool u_useTexture;
uniform int u_fragmentPass;   // 2 translucent, 4 mixed translucent
uniform float u_polygonAlpha; // normalized 5-bit polygon alpha
uniform int u_polygonMode;    // 0 modulation, 1 decal
uniform float u_polygonId;    // normalized 6-bit polygon ID (id / 63)
uniform bool u_polygonFogEnabled;
uniform sampler2D MainTex;
// The active destination state, sampled to apply same-ID rejection before any
// depth write. Full-resolution, nearest-filtered (the renderState contract).
uniform Image u_activeState;
uniform vec2 u_stateSize;

const float CLEAR_POLYGON_ID = 63.0;
// Decode the destination's last-translucent-ID encoding (state A):
// 0 -> none (-1), otherwise id = round(encoded * 64) - 1.
int lastTranslucentId(vec4 dstState)
{
  float encoded = dstState.a;
  if (encoded <= 0.0005) {
    return -1;
  }
  return int(floor(encoded * 64.0 + 0.5)) - 1;
}

void effect()
{
  // Same final alpha5 as map.glsl (MODULATE/DECAL).
  float textureAlpha5 = u_useTexture ? floor(Texel(MainTex, v_sourceUv).a * 31.0 + 0.5) : 31.0;
  int polygonAlpha5 = int(floor(u_polygonAlpha * 31.0 + 0.5));

  int outputAlpha5;
  if (u_polygonMode == 1) {
    outputAlpha5 = polygonAlpha5;
  } else {
    outputAlpha5 = int(floor(float((int(textureAlpha5) + 1) * (polygonAlpha5 + 1) - 1) / 32.0));
  }

  // The translucent/mixed-translucent discard predicate, exactly map.glsl's:
  // pass 2 (translucent) discards fully transparent fragments; pass 4 (mixed
  // translucent) discards both fully transparent and fully opaque fragments
  // (the opaque texels went through the opaque path).
  if (u_fragmentPass == 2) {
    if (outputAlpha5 == 0) discard;
  } else if (u_fragmentPass == 4) {
    if (outputAlpha5 == 0 || outputAlpha5 == 31) discard;
  } else {
    discard;
  }

  int sourceId = int(floor(u_polygonId * CLEAR_POLYGON_ID + 0.5));
  vec2 uv = gl_FragCoord.xy / u_stateSize;
  vec4 dstState = Texel(u_activeState, uv);

  // DS same-ID rejection (melonDS PlotTranslucentPixel): a translucent
  // fragment carrying the same polygon ID as the pixel's last translucent ID
  // is rejected completely -- color, alpha, fog state, ID state, and depth.
  // This reads the ACTIVE destination state's A channel, not the opaque
  // polygon ID R: two translucent polygons with the same ID self-reject even
  // when the stored opaque ID underneath is unrelated.
  if (lastTranslucentId(dstState) == sourceId) {
    discard;
  }

  love_Canvases[0] = vec4(1.0, 0.0, u_polygonFogEnabled ? 1.0 : 0.0, float(sourceId + 1) / 64.0);
}
#endif
