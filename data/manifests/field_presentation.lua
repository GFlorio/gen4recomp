-- Project-owned field presentation tuning. resizeCompensation controls how much
-- window-height growth becomes additional visible world instead of larger map
-- pixels: 0 keeps current framing, 1 keeps approximate pixel size. input is the
-- single bindings table for the semantic Action/Cancel buttons (spec section
-- 11.1); gamepad buttons are fixed by LÖVE convention (south "a" / east "b").

return {
  zoom = {
    manualZoom = 1,
    minZoom = 0.5,
    maxZoom = 1.5,
    step = 0.1,
    referenceHeight = 600,
    resizeCompensation = 0.7,
  },
  input = {
    action = { "z", "space", "return" },
    cancel = { "x", "backspace" },
  },
}
