-- HGSS source mapping for the Professor Oak/profile presentation. Physical
-- archive and member identities are producer-only facts; the compiler turns
-- these records into semantic runtime assets and copies the facts only into
-- dependency provenance.

local resourceResolution = {
  archive = "NARC_data_resdat",
  header = 78,
  charTable = 26,
  paletteTable = 27,
  cellTable = 25,
  animationTable = 24,
  sourceNarcId = 120,
}

local IntroAssets = {
  schema = 3,
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
  genderChoiceBounds = {
    male = { x = 18, y = 25, width = 93, height = 148 },
    female = { x = 144, y = 25, width = 95, height = 148 },
  },
  profileConfirmation = {
    palette = 33,
    base = { char = 37, screen = 48 },
    focus = { char = 42, screen = 50 },
    genders = {
      male = {
        scrollX = 0x88,
        yes = {
          scrollY = 0,
          bounds = { x = 138, y = 26, width = 115, height = 57 },
          textBounds = { x = 136, y = 48, width = 104, height = 24 },
        },
        no = {
          scrollY = 0x1AF,
          bounds = { x = 138, y = 108, width = 115, height = 56 },
          textBounds = { x = 136, y = 128, width = 104, height = 24 },
        },
      },
      female = {
        scrollX = 0,
        yes = {
          scrollY = 0,
          bounds = { x = 10, y = 26, width = 115, height = 57 },
          textBounds = { x = 16, y = 48, width = 104, height = 24 },
        },
        no = {
          scrollY = 0x1AF,
          bounds = { x = 10, y = 108, width = 115, height = 56 },
          textBounds = { x = 16, y = 128, width = 104, height = 24 },
        },
      },
    },
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
      animationIndex = 0,
      paletteOverride = 0,
      sourceCenter = { x = 64, y = 104 },
      resourceResolution = resourceResolution,
    },
    female = {
      resourceSet = 2,
      archive = "intro",
      animationIndex = 0,
      paletteOverride = 1,
      sourceCenter = { x = 192, y = 104 },
      resourceResolution = resourceResolution,
    },
  },
  shrink = {
    male = { palette = 16, chars = { 22, 23, 24, 25 }, screen = 9 },
    female = { palette = 21, chars = { 26, 27, 28, 29 }, screen = 9 },
  },
  ball_open = {
    archive = "intro",
    animationIndex = 3,
    -- Source palette-slot selector resolved by IntroObjPaletteResolver against
    -- resourceSet 5's loaded palette resource, not a local 4bpp bank index
    -- picked independently per sprite. sSpriteTemplates assigns `.pal = 4`
    -- uniformly to every sprite built from resourceSet 5.
    paletteOverride = 4,
    resourceSet = 5,
    resourceResolution = resourceResolution,
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
  resourceResolution = resourceResolution,
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
  resourceResolution = resourceResolution,
  sourceCenter = { x = 160, y = 80 },
}

function IntroAssets.variant(versionId)
  local palette = IntroAssets.background.palettes[versionId]
  assert(palette, "unsupported intro variant: " .. tostring(versionId))
  return palette
end

return IntroAssets
