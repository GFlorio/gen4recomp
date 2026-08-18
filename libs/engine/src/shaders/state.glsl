// DS semantic-state shader. Rasterizes the same world/billboard geometry as
// map.glsl at the DS-pixel-density semantic target (MapRenderer.dsW/dsH, see
// MapRenderer.semanticTargetSize), and writes only the DS state edge marking
// and fog need: the opaque fragment's polygon ID, DS-quantized depth proxy,
// per-polygon fog gate, and validity. It owns no lighting RGB, no fog blend,
// and no edge search -- those stay in map.glsl's color output and edge.glsl's
// final resolve respectively (spec: the semantic pass's job is geometry/UV/
// final-alpha/state only).
//
// The vertex stage is the same world/billboard placement map.glsl uses (see
// that shader's header and position()), without the lighting/normal work: no
// semantic-state channel depends on lit color, so this shader carries no
// normal, light, or material uniforms at all.
//
// The pixel stage computes the same exact DS final-alpha5 map.glsl computes
// for MODULATE/DECAL (mirrored here rather than shared, since GLSL has no
// cross-shader-source include -- see map.glsl's outputAlpha5 derivation for
// the authoritative equations this duplicates), then applies one of three
// fragment predicates selected by u_fragmentPass:
//   0 = opaque:       no discard (the queue only sends here what it already
//                      classified opaque).
//   1 = cutout:        discard when alpha5 == 0 (cutout is binary: 0 or 31 by
//                      classification contract).
//   2 = mixed opaque:  discard unless alpha5 == 31 -- only a mixed material's
//                      fully-opaque texels reach this pass's writes.
// A surviving fragment writes vec4(polygonId/63, dsWbufferDepth, fogGate,
// 1.0) into the single semantic-state canvas -- exactly finalState's old
// packing (see map.glsl's prior header), now the only writer of that state.

varying vec2 v_semanticUv;

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

  v_semanticUv = (u_texMatrix * vec3(VertexTexCoord.xy, 1.0)).xy;

  // See map.glsl's position() for why this custom-projection pass must negate
  // clip Y: LÖVE Canvas framebuffers are Y-inverted relative to the screen,
  // and this shader bypasses LÖVE's compensating flip.
  vec4 clip = u_proj * viewPosition;
  clip.y = -clip.y;
  return clip;
}
#endif

#ifdef PIXEL
uniform bool u_useTexture;
uniform int u_fragmentPass;   // 0 opaque, 1 cutout, 2 mixed opaque
uniform float u_polygonAlpha; // normalized 5-bit polygon alpha
uniform int u_polygonMode;    // 0 modulation, 1 decal
uniform float u_polygonId;    // normalized 6-bit polygon ID (id / 63)
uniform bool u_polygonFogEnabled;
uniform sampler2D MainTex;

// Mirrors map.glsl's dsWbufferDepth exactly -- see that shader for the full
// derivation (gl_FragCoord.w, u_depthWMax, and the 24-bit quantized domain).
uniform float u_depthWMax;
const float DS_DEPTH_MAX = 16777215.0; // 0xFFFFFF

float dsWbufferDepth(float linearEyeDepth)
{
  float fraction = clamp(linearEyeDepth / u_depthWMax, 0.0, 1.0);
  return floor(fraction * DS_DEPTH_MAX);
}

void effect()
{
  // An untextured polygon has no texture alpha to modulate with -- treat it
  // as fully opaque (alpha5 = 31), the same convention map.glsl's untextured
  // vec4(1.0) sample reaches.
  float textureAlpha5 = u_useTexture ? floor(Texel(MainTex, v_semanticUv).a * 31.0 + 0.5) : 31.0;
  int polygonAlpha5 = int(floor(u_polygonAlpha * 31.0 + 0.5));

  int outputAlpha5;
  if (u_polygonMode == 1) {
    // DECAL: final alpha is polygon alpha unconditionally; texture alpha
    // never contributes (see map.glsl's outputAlpha5 for the same rule).
    outputAlpha5 = polygonAlpha5;
  } else {
    outputAlpha5 = int(floor(float((int(textureAlpha5) + 1) * (polygonAlpha5 + 1) - 1) / 32.0));
  }

  if (u_fragmentPass == 1) {
    if (outputAlpha5 == 0) discard;
  } else if (u_fragmentPass == 2) {
    if (outputAlpha5 != 31) discard;
  }

  float dsDepth = dsWbufferDepth(1.0 / gl_FragCoord.w);
  love_Canvases[0] = vec4(u_polygonId, dsDepth, u_polygonFogEnabled ? 1.0 : 0.0, 1.0);
}
#endif
