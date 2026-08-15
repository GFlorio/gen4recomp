-- The application ids shared across the Start Menu policy (targetApplication),
-- the per-runtime application catalogue, and host dispatch: one domain-owned
-- constant table so the ids never repeat as raw protocol strings across
-- module boundaries. The Start Menu's display action ids (vanilla.*) are the
-- policy's own catalog and cross no module boundary, so they are not
-- centralized here. Pure domain module: no love, no I/O.

local FieldApplicationIds = {
  POKEDEX = "pokedex",
  POKEMON = "pokemon",
  BAG = "bag",
  POKEGEAR = "pokegear",
  TRAINER_CARD = "trainer_card",
  SAVE = "save",
  OPTIONS = "options",
}

return FieldApplicationIds
