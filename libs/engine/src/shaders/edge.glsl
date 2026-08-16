// DS edge-marking post-process, run as a full-screen pass over the polygon-ID /
// depth / translucent-attribute target written by map.glsl.
//
// GBATEK ("4000330h..33Fh - EDGE_COLOR") defines the rule: a pixel is marked
// when at least one of its four surrounding pixels (up, down, left, right --
// no diagonals) has a different polygon ID *and* the marked pixel's depth is
// strictly less than that neighbour's, i.e. the marked pixel is in front. The
// depth condition is what suppresses coplanar boundaries: adjacent ground
// batches and flat shadow decals carry different polygon IDs but no depth
// step, so they are never marked. The edge color is chosen by the marked
// pixel's own ID, indexed as id >> 3. The depth comparison is a strict
// integer-domain inequality, never a tolerance-scaled float heuristic.
//
// The green channel holds the DS-quantized W-buffer depth map.glsl computes
// (see its dsWbufferDepth) rather than raw window Z: a perspective near/far of
// 0.1/400 crushes window Z to ~0.993 across the whole field, so silhouette
// steps for anything but very close geometry would fall below any usable
// threshold and go unmarked. The DS depth test works in W-buffer (linear)
// space, where a fixed world gap is detectable at any range; matching that is
// what makes short objects (signposts, hydrants) outline as they do on
// hardware.
//
// Only opaque geometry participates -- "Edge Marking is applied ONLY to opaque
// polygons (including wire-frames)". Translucent draws still stamp this buffer
// so they OCCLUDE the opaque geometry behind them (otherwise a back object
// outlines through a translucent object in front of it), but they carry their
// own real polygon ID (never an invented sentinel) plus a separate
// translucent-attribute flag in the blue channel, and are skipped as edge
// centers below via that flag, so they are never outlined themselves.
//
// Hardware marks a single 256x192 pixel. u_edgeRadius rescales that to the
// current framebuffer so the outline keeps its DS-relative weight.
//
// Edge compositing replaces scene RGB outright (hardware behavior) rather than
// alpha-mixing with it; there is no alpha-mix uniform on this path.

#ifdef PIXEL
uniform Image u_idTex;
uniform vec2 u_texelSize;
uniform vec3 u_edgeColors[8];
uniform int u_edgeRadius;

const int MAX_EDGE_RADIUS = 8;

bool marked(vec2 uv, vec2 offset, float centerId, float centerDepth)
{
  vec3 neighborSample = Texel(u_idTex, uv + offset).rgb;
  bool differentId = abs(neighborSample.r - centerId) > 0.5 / 255.0;
  // Strictly less, no tolerance -- the marked pixel must be in front.
  bool centerInFront = centerDepth < neighborSample.g;
  return differentId && centerInFront;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords)
{
  vec4 scene = Texel(tex, uv);
  vec3 center = Texel(u_idTex, uv).rgb;
  float centerId = center.r;
  float centerDepth = center.g;
  int centerPolygonId = int(floor(centerId * 255.0 + 0.5));

  // Translucent pixels occlude but are never edge centers (opaque + wireframe
  // only): the translucent-attribute flag, not an ID sentinel.
  if (center.b > 0.5) return scene;

  // The rear-plane/wireframe sentinel (255, MapRenderer.REAR_PLANE_ID) is
  // outside the real 0-63 polygon-id domain u_edgeColors indexes; a
  // sentinel-valued center can still be "marked" (it differs from and sits
  // in front of a real neighbor), so this guard must come before any table
  // index below, not only before the marked-pixel loop.
  if (centerPolygonId > 63) return scene;

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
  if (!edge) return scene;

  vec3 edgeColor = u_edgeColors[centerPolygonId / 8];
  // DS hardware edge compositing replaces RGB outright; it does not
  // alpha-mix with the scene color.
  return vec4(edgeColor, scene.a);
}
#endif
