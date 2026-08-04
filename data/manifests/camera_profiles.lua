-- Provisional field-camera profiles, keyed by the map header's cameraType.
-- These are hand-set starting points for the diagnostic game camera, NOT an
-- extraction of the DS overlay camera table; exact values are to be tuned
-- against reference screenshots. All lengths are in field tiles, angles in
-- degrees. cameraType 4 is Elm's Lab (interior, height-restricted); 0 is the
-- default town/route camera. The renderer keeps the original cameraType and
-- must not claim these reproduce the hardware camera.

return {
  [4] = {
    perspectiveDegrees = 35,
    distanceTiles = 18,
    elevationDegrees = 50,
    yawDegrees = 0,
    targetHeightTiles = 0,
  },
  [0] = {
    perspectiveDegrees = 35,
    distanceTiles = 22,
    elevationDegrees = 55,
    yawDegrees = 0,
    targetHeightTiles = 0,
  },
}
