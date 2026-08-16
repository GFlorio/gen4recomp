-- Pure HGSS Start Menu action policy for the implemented normal field
-- context: the canonical action definitions and the progression rules that
-- build the menu's final interactive list. The facts are the seven unlock
-- values the runtime reads from the event-state flags (the four CheckGot*
-- progression gates plus the three FLAG_GOT_BAG+idx unlocks) as ordinary
-- internal data; each source action still separates list presence (the
-- source inhibit masks, StartMenu_GetStartMenuButtonInhibitFlags_Normal,
-- start_menu.c:288-331) from the gameplay unlock gate
-- (FieldSystem_StartMenuActionIsAvailable, start_menu.c:531-556, gates at
-- sys_flags.c:273-289). availableActions processes every source action in
-- canonical insertion order -- present-but-unimplemented actions keep their
-- canonical display positions -- and returns the final records the runtime
-- needs: an entry is interactive exactly when present AND unlocked AND its
-- destination application is registered (the hasApplication predicate).
-- Pure domain module: no love, no I/O. Source evidence: src/start_menu.c at
-- the pinned decomp commit 008257708; full audit in
-- docs/research/start-menu-policy.md.

local FieldApplicationIds = require("libs.engine.src.FieldApplicationIds")

local StartMenuPolicy = {}

-- The seven unlock facts of the internal snapshot: the four progression
-- gates and the three flag-gated unlocks.
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
-- default TRUE). `targetApplication` is the destination application id from
-- FieldApplicationIds (nil when the destination is not an application:
-- RUNNING_SHOES is a controller toggle, RETIRE is a field action, 7 is a
-- removed feature).
local ACTIONS = {
  { id = "vanilla.retire", inhibitedBy = true },
  { id = "vanilla.special_7", inhibitedBy = true },
  {
    id = "vanilla.pokedex",
    targetApplication = FieldApplicationIds.POKEDEX,
    inhibitedBy = "hasPokedex",
    unlockedBy = "hasPokedex",
  },
  {
    id = "vanilla.pokemon",
    targetApplication = FieldApplicationIds.POKEMON,
    inhibitedBy = "hasStarter",
    unlockedBy = "hasStarter",
  },
  {
    id = "vanilla.bag",
    targetApplication = FieldApplicationIds.BAG,
    inhibitedBy = "bagUnlocked",
    unlockedBy = "bagUnlocked",
  },
  {
    id = "vanilla.pokegear",
    targetApplication = FieldApplicationIds.POKEGEAR,
    inhibitedBy = "hasPokegear",
    unlockedBy = "hasPokegear",
  },
  {
    id = "vanilla.trainer_card",
    targetApplication = FieldApplicationIds.TRAINER_CARD,
    unlockedBy = "trainerCardUnlocked",
  },
  {
    id = "vanilla.save",
    targetApplication = FieldApplicationIds.SAVE,
    unlockedBy = "saveUnlocked",
  },
  {
    id = "vanilla.options",
    targetApplication = FieldApplicationIds.OPTIONS,
    unlockedBy = "optionsUnlocked",
  },
  { id = "vanilla.running_shoes" },
  {
    id = "vanilla.special_9",
    targetApplication = FieldApplicationIds.POKEGEAR,
    displayPosition = 7,
  },
  {
    id = "vanilla.special_10",
    targetApplication = FieldApplicationIds.POKEGEAR,
    displayPosition = 8,
  },
}

-- Builds the final interactive action list for one facts snapshot: all
-- source actions are processed in canonical insertion order, so
-- present-but-unimplemented actions keep their canonical display positions,
-- and an entry is interactive exactly when present AND unlocked AND its
-- destination application is registered. Fresh records per call; the facts
-- are never mutated.
---@param value table the seven unlock facts (asserted booleans, unknown keys tolerated)
---@param hasApplication fun(applicationId: string): boolean the application-capability predicate
---@return { id: string, targetApplication: string, displayPosition: integer }[]
function StartMenuPolicy.availableActions(value, hasApplication)
  assert(type(value) == "table", "the start menu policy requires the unlock facts")
  for _, field in ipairs(FACT_FIELDS) do
    assert(type(value[field]) == "boolean", "the start menu policy requires boolean unlock facts")
  end
  assert(type(hasApplication) == "function", "the start menu policy requires the application-capability predicate")
  local actions = {}
  local presentCount = 0
  for _, definition in ipairs(ACTIONS) do
    local inhibitedBy = definition.inhibitedBy
    local present = inhibitedBy == nil or (inhibitedBy ~= true and value[inhibitedBy] == true)
    local unlockedBy = definition.unlockedBy
    local unlocked = unlockedBy == nil or value[unlockedBy] == true
    local targetApplication = definition.targetApplication
    if present and unlocked and targetApplication ~= nil and hasApplication(targetApplication) then
      actions[#actions + 1] = {
        id = definition.id,
        targetApplication = targetApplication,
        displayPosition = definition.displayPosition or presentCount,
      }
    end
    if present then
      presentCount = presentCount + 1
    end
  end
  return actions
end

return StartMenuPolicy
