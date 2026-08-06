-- Project-owned field presentation tuning. resizeCompensation controls how much
-- window-height growth becomes additional visible world instead of larger map
-- pixels: 0 keeps current framing, 1 keeps approximate pixel size.

return {
  zoom = {
    manualZoom = 1,
    minZoom = 0.5,
    maxZoom = 1.5,
    step = 0.1,
    referenceHeight = 600,
    resizeCompensation = 0.7,
  },
}
