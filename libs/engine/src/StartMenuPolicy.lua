-- Pure HGSS Start Menu action policy for the implemented normal field
-- context: the canonical action definitions and the progression rules that
-- build the menu's source list. The strict input is the seven unlock facts
-- the runtime reads from the event-state flags (the four CheckGot*
-- progression gates plus the three FLAG_GOT_BAG+idx unlocks); each output
-- entry separates list presence (the source inhibit masks,
-- StartMenu_GetStartMenuButtonInhibitFlags_Normal, start_menu.c:288-331)
-- from the gameplay unlock gate (FieldSystem_StartMenuActionIsAvailable,
-- start_menu.c:531-556, gates at sys_flags.c:273-289) and carries the
-- canonical display-array position. The policy knows nothing about
-- applications: the runtime intersects the registered destination
-- capabilities against this source list. Pure domain module: no love, no
-- I/O; the caller supplies one strict snapshot (every required key present,
-- no `or false` defaults). Source evidence: src/start_menu.c at the pinned
-- decomp commit 008257708; full audit in docs/research/start-menu-policy.md.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

local StartMenuPolicy = {}

-- The seven required unlock facts of the strict snapshot: the four
-- progression gates and the three flag-gated unlocks.
local FACT_FIELDS = {
  "hasPokedex",
  "hasStarter",
  "bagUnlocked",
  "hasPokegear",
  "trainerCardUnlocked",
  "saveUnlocked",
  "optionsUnlocked",
}

-- The canonical actions in build (insertion) order
-- (StartMenu_BuildActionLists, start_menu.c:483-523): RETIRE, 7, POKEDEX,
-- POKEMON, BAG, POKEGEAR, TRAINER_CARD, SAVE, OPTIONS, RUNNING_SHOES, then
-- the unconditional special Pokégear-family entries 9 and 10 at the reserved
-- display positions 7 and 8. `inhibitedBy` is the presence gate (true =
-- unconditionally inhibited, a fact key = inhibited while that fact is
-- false, absent = never inhibited); `unlockedBy` is the availability gate
-- fact key (absent = always available, matching the source's icon-index-100
-- default TRUE). `targetApplication` is the destination application id (nil
-- when the destination is not an application: RUNNING_SHOES is a controller
-- toggle, RETIRE is a field action, 7 is a removed feature).
local ACTIONS = {
  { sourceAction = "retire", id = "vanilla.retire", inhibitedBy = true },
  { sourceAction = "7", id = "vanilla.special_7", inhibitedBy = true },
  {
    sourceAction = "pokedex",
    id = "vanilla.pokedex",
    targetApplication = "pokedex",
    inhibitedBy = "hasPokedex",
    unlockedBy = "hasPokedex",
  },
  {
    sourceAction = "pokemon",
    id = "vanilla.pokemon",
    targetApplication = "pokemon",
    inhibitedBy = "hasStarter",
    unlockedBy = "hasStarter",
  },
  {
    sourceAction = "bag",
    id = "vanilla.bag",
    targetApplication = "bag",
    inhibitedBy = "bagUnlocked",
    unlockedBy = "bagUnlocked",
  },
  {
    sourceAction = "pokegear",
    id = "vanilla.pokegear",
    targetApplication = "pokegear",
    inhibitedBy = "hasPokegear",
    unlockedBy = "hasPokegear",
  },
  {
    sourceAction = "trainer_card",
    id = "vanilla.trainer_card",
    targetApplication = "trainer_card",
    unlockedBy = "trainerCardUnlocked",
  },
  { sourceAction = "save", id = "vanilla.save", targetApplication = "save", unlockedBy = "saveUnlocked" },
  { sourceAction = "options", id = "vanilla.options", targetApplication = "options", unlockedBy = "optionsUnlocked" },
  { sourceAction = "running_shoes", id = "vanilla.running_shoes" },
  { sourceAction = "9", id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
  { sourceAction = "10", id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
}

local function invalidSnapshot(message, context)
  Errors.raise(FieldErrors.START_MENU_POLICY_INVALID_SNAPSHOT, message, context)
end

-- Strict snapshot validation (raising): exactly the seven unlock facts, all
-- booleans. Missing keys and unknown keys are errors, never defaults.
---@param value table
---@return table facts
local function validateSnapshot(value)
  if type(value) ~= "table" then
    invalidSnapshot("the start menu policy snapshot must be a table")
  end
  for key in pairs(value) do
    local known = false
    for _, field in ipairs(FACT_FIELDS) do
      if key == field then
        known = true
      end
    end
    if not known then
      invalidSnapshot("unknown start menu policy fact", { key = key })
    end
  end
  for _, field in ipairs(FACT_FIELDS) do
    if type(value[field]) ~= "boolean" then
      invalidSnapshot("the unlock fact is required", { field = field })
    end
  end
  return value
end

-- Builds the ordered action list for one strict snapshot. Returns the
-- canonical build slots (12), each with present / unlocked /
-- targetApplication / displayPosition modeled separately; the runtime
-- intersects the registered destination capabilities. Fresh tables per call;
-- the snapshot is never mutated.
---@param value table the strict snapshot (the seven unlock facts)
---@return table[]
function StartMenuPolicy.build(value)
  local facts = validateSnapshot(value)
  local entries = {}
  local presentCount = 0
  for _, definition in ipairs(ACTIONS) do
    local inhibitedBy = definition.inhibitedBy
    local present = inhibitedBy == nil or (inhibitedBy ~= true and facts[inhibitedBy] == true)
    local unlockedBy = definition.unlockedBy
    local unlocked = unlockedBy == nil or facts[unlockedBy] == true
    local entry = {
      id = definition.id,
      targetApplication = definition.targetApplication,
      present = present,
      unlocked = unlocked,
    }
    if present then
      entry.displayPosition = definition.displayPosition or presentCount
      presentCount = presentCount + 1
    end
    entries[#entries + 1] = entry
  end
  return entries
end

return StartMenuPolicy
