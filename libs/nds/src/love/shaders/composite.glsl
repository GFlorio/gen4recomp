// DS translucent compositor. A full-screen pass that applies the exact
// integer DS blend/state equations to one accepted source-fragment buffer
// (source.glsl's sourceColor/sourceMeta) against the active destination
// color/state pair, writing the result into the inactive destination pair
// (the ping-pong halves of the compositor loop in GxRenderer:draw). The
// destination is never sampled and written in the same pass: the composite
// reads the active pair and writes the inactive one, then the renderer swaps
// which pair is active.
//
// The modeled DS contract (melonDS GPU3D_Soft.cpp AlphaBlend /
// PlotTranslucentPixel, HGSS field alpha blending):
//   1. a fragment already rejected by the source pass never reaches here
//      (sourceMeta.r == 0 -> the destination is copied unchanged);
//   2. dstAlpha5 == 0 -> the accepted source replaces the destination
//      color/alpha;
//   3. otherwise, with w = srcAlpha5 + 1 (1..31), each RGB6 channel is
//      out = ((src * w) + (dst * (32 - w))) >> 5;
//   4. output alpha5 = max(srcAlpha5, dstAlpha5);
//   5. the opaque polygon ID (R) is never replaced by a translucent draw;
//   6. the DS Z depth (G) is always preserved; supported translucent source
//      never writes depth;
//   7. the new fog gate B = destination fog gate AND source fog flag;
//   8. the new last-translucent-ID A = the accepted source polygon ID,
//      encoded (id + 1) / 64 (0 = none).
//
// All RGB math is integer RGB6 (0..63) and alpha is integer alpha5 (0..31);
// conversion back to normalized framebuffer values happens only after the
// integer arithmetic. The composite draw uses replace semantics -- no second
// host alpha blend is applied to already-computed output.

#ifdef PIXEL
uniform Image u_sourceColor;
uniform Image u_sourceMeta;
uniform Image u_activeColor;
uniform Image u_activeState;
uniform vec2 u_size;

// Decode the source polygon ID from sourceMeta.a ((id + 1) / 64). The
// encoding is chosen so all 6-bit IDs survive normalized rgba8 storage.
int sourceId(vec4 meta)
{
  return int(floor(meta.a * 64.0 + 0.5)) - 1;
}

void effect()
{
  vec2 uv = gl_FragCoord.xy / u_size;
  vec4 meta = Texel(u_sourceMeta, uv);
  vec4 dstColor = Texel(u_activeColor, uv);
  vec4 dstState = Texel(u_activeState, uv);

  vec4 outColor = dstColor;
  vec4 outState = dstState;

  if (meta.r > 0.5) {
    vec4 srcColor = Texel(u_sourceColor, uv);
    int srcA5 = int(floor(srcColor.a * 31.0 + 0.5));
    int dstA5 = int(floor(dstColor.a * 31.0 + 0.5));
    int srcId = sourceId(meta);

    if (dstA5 == 0) {
      // Accepted source replaces the destination color/alpha outright.
      outColor = srcColor;
    } else {
      // DS integer blend: w = srcA5 + 1 (1..31), each channel
      // out = ((src * w) + (dst * (32 - w))) >> 5, in RGB6.
      int w = srcA5 + 1;
      vec3 src6 = floor(srcColor.rgb * 63.0 + 0.5);
      vec3 dst6 = floor(dstColor.rgb * 63.0 + 0.5);
      vec3 out6 = floor((src6 * float(w) + dst6 * float(32 - w)) / 32.0);
      outColor.rgb = out6 / 63.0;
      outColor.a = float(max(srcA5, dstA5)) / 31.0;
    }

    // State: opaque polygon ID R and DS Z depth G are preserved.
    // B = destination fog gate AND source fog flag (rule 7).
    outState.b = dstState.b > 0.5 && meta.b > 0.5 ? 1.0 : 0.0;
    // A = the accepted source polygon ID, encoded (id + 1) / 64 (rule 8).
    outState.a = float(srcId + 1) / 64.0;
  }

  love_Canvases[0] = outColor;
  love_Canvases[1] = outState;
}
#endif
