-- Development coordinate anchors and provisional debug-player spawns for the
-- two target maps, keyed by semantic symbol. These are DEVELOPMENT ANCHORS, not
-- runtime warp objects: the diagnostic overlay draws them so a human can confirm
-- the coordinate system, and the debug player spawns from the recorded tile.
-- Coordinates are decomp-derived (see the sprint's confirmed target facts):
-- Elm's Lab has a New Bark warp at local (4,14); New Bark's laboratory-entry
-- warp is global (684,393) == local (12,9) relative to the cell origin (672,384).
-- Spawns are provisional and validated at load time (nearest passable fallback).
-- No love dependency.

return {
  MAP_NEW_BARK_ELMS_LAB_1F = {
    spawn = { x = 4, z = 13, facing = "north" },
    anchors = {
      { label = "warp -> New Bark", localX = 4, localZ = 14 },
    },
  },
  MAP_NEW_BARK = {
    spawn = { x = 12, z = 10, facing = "south" },
    anchors = {
      { label = "lab entry warp", localX = 12, localZ = 9, globalX = 684, globalZ = 393 },
    },
  },
}
