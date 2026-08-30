// Recolors a categorical glyph mask against a caller-supplied palette. The
// mask texture is not RGB art: each texel's alpha gates transparency and its
// R/G/B channel names the source glyph class (foreground/shadow/background),
// exactly the FieldFontCompiler encoding (0,0,0,0 transparent; (255,0,0,255)
// foreground; (0,255,0,255) shadow; (0,0,255,255) background). Classes are
// read from the exact channel, never a fuzzy RGB distance, so any palette
// color -- including one that happens to look reddish or greenish -- can
// never be misread as a different glyph class.

#ifdef PIXEL
uniform vec4 u_foreground;
uniform vec4 u_shadow;
uniform vec4 u_background;

vec4 effect(vec4 tint, Image tex, vec2 uv, vec2 screenCoords)
{
  vec4 mask = Texel(tex, uv);

  if (mask.a < 0.5) {
    return vec4(0.0);
  }

  vec4 sourceColor;
  if (mask.r > 0.5) {
    sourceColor = u_foreground;
  } else if (mask.g > 0.5) {
    sourceColor = u_shadow;
  } else {
    sourceColor = u_background;
  }

  return sourceColor * tint;
}
#endif
