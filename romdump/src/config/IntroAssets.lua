-- HGSS source mapping for the Professor Oak/profile presentation. Physical
-- archive and member identities are producer-only facts; the compiler turns
-- these records into semantic runtime assets and copies the facts only into
-- dependency provenance.

local IntroAssets = {
  schema = 2,
  provenance = {
    repo = "pret/pokeheartgold",
    commit = "f45f4fd1368e8809515540404408fd2bc71974a8",
    sources = {
      "src/oaks_speech.c",
      "src/oaks_speech_obj.c",
      "files/demo/intro/intro.mk",
    },
  },
  archive = "intro",
  background = {
    char = 0,
    screen = 3,
    palettes = { heartgold = 1, soulsilver = 2 },
  },
  genderBackground = {
    char = 32,
    screen = 51,
    palettes = { heartgold = 30, soulsilver = 31 },
  },
  oak = { char = 10, palette = 11, screen = 9 },
  gender = {
    male = { char = 12, palette = 16, screen = 9 },
    female = { char = 17, palette = 21, screen = 9 },
  },
  genderSelectors = {
    male = {
      resourceSet = 1,
      archive = "intro",
      char = 34,
      palette = 33,
      cell = 53,
      animation = 54,
      animationIndex = 0,
      paletteOverride = 0,
    },
    female = {
      resourceSet = 2,
      archive = "intro",
      char = 35,
      palette = 33,
      cell = 55,
      animation = 56,
      animationIndex = 0,
      paletteOverride = 0,
    },
  },
  shrink = {
    male = { palette = 16, chars = { 22, 23, 24, 25 } },
    female = { palette = 21, chars = { 26, 27, 28, 29 } },
  },
  ball_open = {
    archive = "intro",
    char = 64,
    palette = 63,
    cell = 65,
    animation = 66,
    animationIndex = 3,
    paletteOverride = 5,
    resourceSet = 5,
    resourceResolution = {
      archive = "NARC_data_resdat",
      header = 78,
      charTable = 26,
      paletteTable = 27,
      cellTable = 25,
      animationTable = 24,
    },
    sourceCenter = { x = 160, y = 80 },
  },
}

IntroAssets.marill_appear = {
  archive = IntroAssets.ball_open.archive,
  char = IntroAssets.ball_open.char,
  palette = IntroAssets.ball_open.palette,
  cell = IntroAssets.ball_open.cell,
  animation = IntroAssets.ball_open.animation,
  animationIndex = 1,
  paletteOverride = 4,
  resourceSet = IntroAssets.ball_open.resourceSet,
  resourceResolution = IntroAssets.ball_open.resourceResolution,
  sourceCenter = { x = 160, y = 80 },
}

IntroAssets.marill = {
  archive = IntroAssets.ball_open.archive,
  char = IntroAssets.ball_open.char,
  palette = IntroAssets.ball_open.palette,
  cell = IntroAssets.ball_open.cell,
  animation = IntroAssets.ball_open.animation,
  animationIndex = 2,
  paletteOverride = 4,
  resourceSet = IntroAssets.ball_open.resourceSet,
  resourceResolution = IntroAssets.ball_open.resourceResolution,
  sourceCenter = { x = 160, y = 80 },
}

function IntroAssets.variant(versionId)
  local palette = IntroAssets.background.palettes[versionId]
  assert(palette, "unsupported intro variant: " .. tostring(versionId))
  return palette
end

return IntroAssets
