-- Independent source timing facts for production-composed movement acceptance.
-- These literals are test evidence, not a mirror of runtime calibration.

local MovementTimingOracle = {
  source = {
    repository = "pret/pokeheartgold",
    commit = "0985e8718df4f25e64d6507d89c0c97c0d288981",
    files = {
      "asm/unk_02062108.s",
      "asm/overlay_01_022001E4.s",
    },
  },
  newBark = {
    walkInPlaceFastTicks = 5,
    exclamationTicks = 33,
  },
  jump = {
    -- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
    -- asm/unk_02062108.s commands 48-51 and 52-55.
    zeroFastTicks = 8,
    nearFastTicks = 8,
  },
}

return MovementTimingOracle
