-- Declared fresh-field starting locations for the currently configured maps,
-- keyed by semantic symbol. These are boot spawns consumed by FieldRuntime's
-- declared-spawn contract, not runtime warp objects. Coordinates are source-derived:
-- Elm's Lab starts on the New Bark warp side of the lab; New Bark starts on
-- the lab-entry side. No love dependency.

return {
  MAP_NEW_BARK_ELMS_LAB_1F = {
    x = 4,
    z = 13,
    facing = "north",
  },
  MAP_NEW_BARK = {
    x = 12,
    z = 10,
    facing = "south",
  },
}
