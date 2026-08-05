// DS edge-marking post-process, run as a full-screen pass over the polygon-ID /
// depth target written by map.glsl.
//
// GBATEK ("4000330h..33Fh - EDGE_COLOR") defines the rule: a pixel is marked
// when at least one of its four surrounding pixels (up, down, left, right --
// no diagonals) has a different polygon ID *and* the marked pixel's depth is
// LESS than that neighbour's, i.e. the marked pixel is in front. The depth
// condition is what suppresses coplanar boundaries: adjacent ground batches
// and flat shadow decals carry different polygon IDs but no depth step, so
// they are never marked. The edge color is chosen by the marked pixel's own
// ID, indexed as id >> 3.
//
// The green channel holds LINEAR eye-space depth (world units), not window Z.
// A perspective near/far of 0.1/400 crushes window Z to ~0.993 across the whole
// field, so silhouette steps for anything but very close geometry fall below any
// usable threshold and go unmarked. The DS depth test works in W-buffer (linear)
// space, where a fixed world gap is detectable at any range; matching that is
// what makes short objects (signposts, hydrants) outline as they do on hardware.
//
// Only opaque geometry participates -- "Edge Marking is applied ONLY to opaque
// polygons (including wire-frames)". Translucent draws still stamp this buffer so
// they OCCLUDE the opaque geometry behind them (otherwise a back object outlines
// through a translucent object in front of it), but they carry a sentinel ID and
// are skipped as edge centers below, so they are never outlined themselves.
//
// Hardware marks a single 256x192 pixel. u_edgeRadius rescales that to the
// current framebuffer so the outline keeps its DS-relative weight; the depth
// threshold scales with the step so a receding surface is rejected just as
// firmly at the outer steps as at the innermost one.

#ifdef PIXEL
uniform Image u_idTex;
uniform vec2 u_texelSize;
uniform vec3 u_edgeColors[8];
uniform float u_edgeAlpha;
uniform int u_edgeRadius;

const int MAX_EDGE_RADIUS = 8;

// Minimum eye-space depth step, in world units per unit of sampling distance,
// that a neighbour must exceed to count as a genuine occluding edge rather than
// the linear-depth slope of a surface shared with the center pixel or the small
// lift of a near-coplanar decal (an object's ground shadow sits just above the
// floor; below this it reads as flat and is left unmarked, as on hardware).
const float DEPTH_STEP_TOLERANCE = 0.30;

// Sentinel ID stamped by translucent fragments (MapRenderer.TRANSLUCENT_SENTINEL_ID
// / 255). Such a pixel occludes what is behind it in this buffer but is never
// itself outlined.
const float TRANSLUCENT_ID = 254.0 / 255.0;

bool marked(vec2 uv, vec2 offset, float centerId, float centerZ, float step)
{
  vec2 n = Texel(u_idTex, uv + offset).rg;
  bool differentId = abs(n.r - centerId) > 0.5 / 255.0;
  bool farther = n.g > centerZ + DEPTH_STEP_TOLERANCE * step;
  return differentId && farther;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
{
  vec4 scene = Texel(tex, uv);
  vec2 center = Texel(u_idTex, uv).rg;
  float centerId = center.r;
  float centerZ = center.g;

  // Translucent pixels occlude but are never edge centers (opaque + wireframe only).
  if (abs(centerId - TRANSLUCENT_ID) < 0.5 / 255.0) return scene;

  bool edge = false;
  for (int i = 1; i <= MAX_EDGE_RADIUS; i++) {
    if (i > u_edgeRadius) break;
    float step = float(i);
    vec2 dx = vec2(u_texelSize.x * step, 0.0);
    vec2 dy = vec2(0.0, u_texelSize.y * step);
    if (marked(uv, dx, centerId, centerZ, step)
      || marked(uv, -dx, centerId, centerZ, step)
      || marked(uv, dy, centerId, centerZ, step)
      || marked(uv, -dy, centerId, centerZ, step)) {
      edge = true;
      break;
    }
  }
  if (!edge) return scene;

  int id = int(floor(centerId * 255.0 + 0.5));
  vec3 ec = u_edgeColors[id / 8];
  return vec4(mix(scene.rgb, ec, u_edgeAlpha), scene.a);
}
#endif
