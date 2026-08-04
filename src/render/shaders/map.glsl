// Map/building shader. The vertex stage applies the model/view/projection
// chain supplied as explicit uniforms (love's own transform is unused for 3D)
// and forwards the world-space normal. The pixel stage samples the material
// texture (or white when untextured), multiplies by the interpolated vertex
// color and the material diffuse uniform, applies a gentle ambient+directional
// term so faces read as shaped rather than flat, and does alpha-mask discard so
// color-zero texels do not leave opaque halos. Lighting is intentionally MVP:
// normals and uniforms are preserved so it can improve without recompiling any
// mesh.

varying vec3 v_normal;

#ifdef VERTEX
attribute vec3 VertexNormal;

uniform mat4 u_proj;
uniform mat4 u_view;
uniform mat4 u_model;

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  v_normal = mat3(u_model) * VertexNormal;
  return u_proj * u_view * u_model * vertex_position;
}
#endif

#ifdef PIXEL
uniform vec4 u_diffuse;      // material diffuse, 0..1
uniform bool u_useTexture;
uniform int u_alphaMode;     // 0 opaque, 1 cutout, 2 translucent
uniform float u_alphaCutoff;
uniform float u_polygonAlpha; // normalized 5-bit polygon alpha
uniform int u_polygonMode;    // 0 modulation/toon, 1 decal

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
{
  vec4 base = u_useTexture ? Texel(tex, uv) : vec4(1.0);
  vec4 outc = base * color * u_diffuse;

  vec3 n = normalize(v_normal);
  float ndl = max(dot(n, normalize(vec3(0.3, 1.0, 0.5))), 0.0);
  float light = 0.6 + 0.4 * ndl;
  outc.rgb *= light;

  // DS 5-bit alpha composition. Recover texture alpha in 5 bits with rounding,
  // combine with polygon alpha for modulation/toon, or use polygon alpha for decal.
  float At = outc.a;
  int At5 = int(floor(At * 31.0 + 0.5));
  int Ap5 = int(floor(u_polygonAlpha * 31.0 + 0.5));
  int Aout5;
  if (u_polygonMode == 1) {
    Aout5 = Ap5;
  } else {
    Aout5 = int(floor(float((At5 + 1) * (Ap5 + 1) - 1) / 32.0));
  }
  outc.a = float(Aout5) / 31.0;

  if (u_alphaMode == 1 && outc.a < u_alphaCutoff) {
    discard;
  }
  return outc;
}
#endif
