-- The checked-in initial player profile and gameplay options: the demo
-- session's starting values, copied and strictly validated by a fresh field
-- session (see libs/engine/src/PlayerData.lua). The name must be 1..7
-- glyphs encodable by the generated field font, the gender one of the
-- gendered-message values (0 = male, 1 = female), and the text frame index
-- must resolve to an imported dialogue frame style. A resumed session uses
-- the saved player-data bucket, never this manifest. Pure data; no love
-- dependency.

return {
  profile = {
    name = "GOLD",
    gender = 0,
    trainerId = 0,
    money = 3000,
  },
  options = {
    textFrame = 0,
    textSpeed = "mid",
  },
}
