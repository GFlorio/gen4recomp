// DS-shaped map/building shader. The vertex stage resolves each vertex's color
// source (literal COLOR, field-profile diffuse, or NORMAL lighting), computes
// DS lighting in camera/vector space, and forwards the resulting RGB. The pixel
// stage samples the texture, applies modulation or decal combination, composes
// the 5-bit polygon alpha, and discards alpha-zero fragments for cutout draws.
// No fake directional light or second diffuse multiplication remains.
//
// The vertex-lighting algebra below (computeDsLighting, dsLightContribution,
// quantizeRgb5) is the shared DS-lighting contract: colors enter normalized as
// c/31, contributions sum as lightColor * (ambient + diffuse*ld + specular*ndh),
// and the result clamps to [0,1] and quantizes to 5 bits with round-half-up.
// Each light additionally requires the polygon's light-mask bit: the renderer
// sends the draw item's 4-bit mask decoded into u_lightMask (one 0/1 float per
// light), so a light contributes only when the profile enables it AND the
// polygon's mask admits it (GBATEK POLYGON_ATTR light mask). The pure-Lua
// reference libs/engine/src/DsLighting.lua mirrors this algebra, and
// ds_lighting_test locks the agreement at midrange values.

varying vec3 v_dsColor;

#ifdef VERTEX
// VertexColor is a LÖVE built-in attribute; do not redeclare it.
attribute float VertexColorSource;
attribute vec3 VertexNormal;

uniform mat4 u_proj;
uniform mat4 u_view;
uniform mat4 u_model;
uniform mat3 u_normalMatrix;

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
uniform vec3 u_diffuseColor;
uniform vec3 u_ambientColor;
uniform vec3 u_specularColor;
uniform vec3 u_emissionColor;

const vec3 VIEW_DIRECTION = vec3(0.0, 0.0, 1.0);

vec3 dsLightContribution(vec3 normal, vec3 L, vec3 lightColor)
{
  float ndl = dot(L, normal);
  float ld = max(0.0, -ndl);

  vec3 H = normalize(-L + VIEW_DIRECTION);
  float ndh = max(0.0, dot(normal, H));

  vec3 contrib = u_ambientColor + u_diffuseColor * ld + u_specularColor * ndh;
  return lightColor * contrib;
}

vec3 computeDsLighting(vec3 normal)
{
  vec3 acc = u_emissionColor;

  if (u_lightEnabled0 && u_lightMask.x > 0.5)
    acc += dsLightContribution(normal, normalize(u_lightVector0), u_lightColor0);
  if (u_lightEnabled1 && u_lightMask.y > 0.5)
    acc += dsLightContribution(normal, normalize(u_lightVector1), u_lightColor1);
  if (u_lightEnabled2 && u_lightMask.z > 0.5)
    acc += dsLightContribution(normal, normalize(u_lightVector2), u_lightColor2);
  if (u_lightEnabled3 && u_lightMask.w > 0.5)
    acc += dsLightContribution(normal, normalize(u_lightVector3), u_lightColor3);

  return clamp(acc, 0.0, 1.0);
}

vec3 quantizeRgb5(vec3 c)
{
  return floor(c * 31.0 + 0.5) / 31.0;
}

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vec3 normal = normalize(u_normalMatrix * VertexNormal);
  int src = int(floor(VertexColorSource + 0.5));

  if (src == 0) {
    v_dsColor = quantizeRgb5(VertexColor.rgb);
  } else if (src == 2) {
    v_dsColor = quantizeRgb5(u_diffuseColor);
  } else {
    v_dsColor = quantizeRgb5(computeDsLighting(normal));
  }

  // LÖVE Canvas framebuffers are Y-inverted relative to the screen, and this
  // custom projection bypasses LÖVE's compensating flip; negate clip Y so the
  // scene renders upright (and with correct winding) into the offscreen canvas.
  vec4 clip = u_proj * u_view * u_model * vertex_position;
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
uniform sampler2D MainTex;

void effect()
{
  vec2 uv = VaryingTexCoord.xy;
  vec4 base = u_useTexture ? Texel(MainTex, uv) : vec4(1.0);

  vec3 outRgb;
  if (u_polygonMode == 1) {
    outRgb = base.rgb;
  } else {
    outRgb = base.rgb * v_dsColor;
  }

  float At = base.a;
  int At5 = int(floor(At * 31.0 + 0.5));
  int Ap5 = int(floor(u_polygonAlpha * 31.0 + 0.5));
  int Aout5;
  if (u_polygonMode == 1) {
    Aout5 = Ap5;
  } else {
    Aout5 = int(floor(float((At5 + 1) * (Ap5 + 1) - 1) / 32.0));
  }
  float alpha = float(Aout5) / 31.0;

  if (u_alphaMode == 1 && alpha < u_alphaCutoff) {
    discard;
  }

  love_Canvases[0] = vec4(outRgb, alpha);
  // Green holds LINEAR eye-space depth (world units) for edge marking: perspective
  // window Z is too crushed at this near/far to resolve short-object silhouettes.
  // gl_FragCoord.w is 1/clip.w and clip.w is the eye-space distance, so 1/w = depth.
  love_Canvases[1] = vec4(u_polygonId, 1.0 / gl_FragCoord.w, 0.0, 1.0);
}
#endif
