-- HGSS source mapping for the Professor Oak/profile presentation. Physical
-- archive and member identities are producer-only facts; the compiler turns
-- these records into semantic runtime assets and copies the facts only into
-- dependency provenance.

return {
  schema = 1,
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
  background = { char = 0, palette = 1, screen = 44 },
  oak = { char = 10, palette = 11, screen = 9 },
  marill = {
    char = 60,
    palette = 59,
    cell = 61,
    animation = 62,
    animationIndex = 0,
  },
  gender = {
    male = { char = 12, palette = 16, screen = 9 },
    female = { char = 17, palette = 21, screen = 9 },
    indicator = { char = 37, palette = 33, screen = 47 },
  },
  shrink = {
    male = { palette = 16, chars = { 12, 22, 23, 24, 25 } },
    female = { palette = 21, chars = { 17, 26, 27, 28, 29 } },
  },
}
