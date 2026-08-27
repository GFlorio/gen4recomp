-- HGSS field-effect source selections. These are producer-only facts from
-- the curated field_static_models archive; generated assets carry semantic
-- definitions and cache references instead of source archive details.

return {
  schema = 1,
  archive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  animationArchive = {
    alias = "field_static_models",
    path = "a/1/0/3",
  },
  effects = {
    warp_entrance = {
      renderer = 3,
      modelMembers = { 85 },
      animationMembers = {},
    },
    tall_grass = {
      renderer = 8,
      modelMembers = { 126 },
      animationMembers = { 140 },
      lifecycle = {
        holdFrame = 12,
        holdUntilOwnerMoves = true,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
    very_tall_grass = {
      renderer = 12,
      modelMembers = { 122 },
      animationMembers = { 146 },
      lifecycle = {
        holdFrame = 12,
        holdUntilOwnerMoves = true,
      },
      placementOffset = { x = 0, y = 0, z = 0.625 },
    },
  },
}
