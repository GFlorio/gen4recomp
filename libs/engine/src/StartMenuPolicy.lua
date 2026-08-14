-- Pure HGSS Start Menu action policy: the canonical action definitions and
-- the context/progression rules that build the menu's action list. One
-- authoritative implementation of ordering, presence (the inhibit masks),
-- vanilla availability (the CheckGot* gates), and the capability split
-- (present / vanillaEnabled / targetApplication modeled separately; the
-- derived capability projections consume an injected application-id set,
-- never an application registry). Pure domain module: no love, no I/O, no
-- raw flags/registries; the caller supplies one strict snapshot (every
-- required key present, no `or false` defaults). Source evidence:
-- src/start_menu.c (StartMenuAction 49-63, sStartMenuActions 176-190,
-- StartMenu_BuildActionLists 483-523, the inhibit masks 288-331,
-- FieldSystem_ShouldDrawStartMenuIcon 535-556) and
-- include/constants/start_menu_icons.h at the pinned decomp commit
-- 008257708; full audit in docs/research/start-menu-policy.md.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

local StartMenuPolicy = {}

-- The named field contexts of the strict snapshot. Special contexts the
-- runtime cannot represent yet report normal_field and stay covered by
-- pure fixtures.
StartMenuPolicy.CONTEXTS = {
  "normal_field",
  "amity_square",
  "safari",
  "bug_contest",
  "pal_park",
  "battle_tower_partner_room",
  "colosseum",
  "union_room",
}

-- The reserved mod-facing action ids: mods cannot replace these
-- implicitly.
StartMenuPolicy.RESERVED_IDS = {
  "vanilla.pokedex",
  "vanilla.pokemon",
  "vanilla.bag",
  "vanilla.pokegear",
  "vanilla.trainer_card",
  "vanilla.save",
  "vanilla.options",
  "vanilla.running_shoes",
}

-- The required progression booleans of the strict snapshot.
local PROGRESSION_FIELDS = { "hasPokedex", "hasStarter", "bagUnlocked", "hasPokegear" }

-- The canonical actions in build (insertion) order
-- (StartMenu_BuildActionLists, start_menu.c:483-523): RETIRE, 7, POKEDEX,
-- POKEMON, BAG, the POKEGEAR slot, TRAINER_CARD, SAVE, OPTIONS,
-- RUNNING_SHOES, then the unconditional special Pokégear-family entries 9
-- and 10 at the reserved display positions 7 and 8. `message` is the
-- pinned bank-0196 ref (sStartMenuActions ident); `targetApplication` is
-- the destination application id (nil when the destination is not an
-- application: RUNNING_SHOES is a controller toggle, RETIRE is a field
-- action, 7 is a removed feature, and 12's handler is an unk function).
local ACTIONS = {
  { sourceAction = "retire", id = "vanilla.retire", message = "msg.hgss.0196.00008" },
  { sourceAction = "7", id = "vanilla.special_7", message = "msg.hgss.0196.00007" },
  { sourceAction = "pokedex", id = "vanilla.pokedex", message = "msg.hgss.0196.00000", targetApplication = "pokedex" },
  { sourceAction = "pokemon", id = "vanilla.pokemon", message = "msg.hgss.0196.00001", targetApplication = "pokemon" },
  { sourceAction = "bag", id = "vanilla.bag", message = "msg.hgss.0196.00002", targetApplication = "bag" },
  {
    sourceAction = "pokegear",
    id = "vanilla.pokegear",
    message = "msg.hgss.0196.00014",
    targetApplication = "pokegear",
  },
  {
    sourceAction = "trainer_card",
    id = "vanilla.trainer_card",
    message = "msg.hgss.0196.00003",
    targetApplication = "trainer_card",
  },
  { sourceAction = "save", id = "vanilla.save", message = "msg.hgss.0196.00004", targetApplication = "save" },
  { sourceAction = "options", id = "vanilla.options", message = "msg.hgss.0196.00005", targetApplication = "options" },
  { sourceAction = "running_shoes", id = "vanilla.running_shoes", message = "msg.hgss.0196.00006" },
  {
    sourceAction = "9",
    id = "vanilla.special_9",
    message = "msg.hgss.0196.00014",
    targetApplication = "pokegear",
    displayPosition = 7,
  },
  {
    sourceAction = "10",
    id = "vanilla.special_10",
    message = "msg.hgss.0196.00014",
    targetApplication = "pokegear",
    displayPosition = 8,
  },
}

-- The POKEGEAR slot occupant in the union room: action 12 replaces POKEGEAR
-- when unk_350 is set (start_menu.c:501-507, sub_0203BCDC:236-244). Its
-- handler sub_0203D2CC (start_menu.c:1158-1162) is an unk field-state
-- function, so it gets no application destination.
local SPECIAL_12 = {
  sourceAction = "12",
  id = "vanilla.special_12",
  message = "msg.hgss.0196.00014",
}

-- Context inhibit masks, keyed by source action; true = unconditionally
-- inhibited, a string = a progression boolean that inhibits when false.
-- The special contexts replace the normal mask entirely
-- (start_menu.c:288-331). Amity Square adds POKEMON|BAG to the normal
-- gates (start_menu.c:302-304); the mask is modeled per the spec although
-- the source check is dead in retail (MapHeader_MapIsAmitySquare always
-- returns FALSE, map_header.c:222-224).
local CONTEXT_MASKS = {
  normal_field = {
    retire = true,
    ["7"] = true,
    pokedex = "hasPokedex",
    pokemon = "hasStarter",
    bag = "bagUnlocked",
    pokegear = "hasPokegear",
  },
  amity_square = {
    retire = true,
    ["7"] = true,
    pokemon = true,
    bag = true,
    pokedex = "hasPokedex",
    pokegear = "hasPokegear",
  },
  safari = {
    save = true,
    ["7"] = true,
  },
  bug_contest = {
    bag = true,
    save = true,
    ["7"] = true,
  },
  pal_park = {
    bag = true,
    save = true,
    ["7"] = true,
  },
  battle_tower_partner_room = {
    pokedex = true,
    bag = true,
    save = true,
    ["7"] = true,
    retire = true,
    pokegear = true,
  },
  colosseum = {
    pokedex = true,
    save = true,
    ["7"] = true,
    retire = true,
    pokegear = true,
  },
  union_room = {
    save = true,
    retire = true,
  },
}

for _, name in ipairs(StartMenuPolicy.CONTEXTS) do
  assert(CONTEXT_MASKS[name] ~= nil, "context mask missing for " .. name)
end

-- The full semantic canonical action order in build sequence: the
-- mod Start Menu registry resolves before/after placement constraints
-- against this order, never against the currently visible subset. Fresh
-- table per call.
---@return string[]
function StartMenuPolicy.canonicalOrder()
  local ids = {}
  for index, action in ipairs(ACTIONS) do
    ids[index] = action.id
  end
  return ids
end

-- The availability gates behind vanillaEnabled. The four CheckGot* gated
-- actions read their snapshot boolean (FieldSystem_ShouldDrawStartMenuIcon,
-- start_menu.c:535-556, gates at sys_flags.c:273-289); every other action's
-- icon index is 100 so the gate's default TRUE applies. TRAINER_CARD/SAVE/
-- OPTIONS keep their canonical unlock state (the FLAG_GOT_BAG+idx sysflags
-- are set in the very first scripted conversation, scr_seq_0845_T20R0201.s)
-- because the strict snapshot carries no field for them.
local VANILLA_GATES = {
  pokedex = "hasPokedex",
  pokemon = "hasStarter",
  bag = "bagUnlocked",
  pokegear = "hasPokegear",
}

local function invalidSnapshot(message, context)
  Errors.raise(FieldErrors.START_MENU_POLICY_INVALID_SNAPSHOT, message, context)
end

-- Strict snapshot validation (raising): context is a named enum,
-- progression carries exactly the four required booleans, and capabilities
-- is an array of distinct non-empty application ids. Missing keys and
-- unknown keys are errors, never defaults.
---@param value table
---@return string context
---@return table progression
---@return table capabilities
local function validateSnapshot(value)
  if type(value) ~= "table" then
    invalidSnapshot("the start menu policy snapshot must be a table")
  end
  for key in pairs(value) do
    if key ~= "context" and key ~= "progression" and key ~= "capabilities" then
      invalidSnapshot("unknown snapshot key", { key = key })
    end
  end
  if value.context == nil then
    invalidSnapshot("the snapshot must carry the context")
  end
  if not CONTEXT_MASKS[value.context] then
    Errors.raise(
      FieldErrors.START_MENU_POLICY_UNKNOWN_CONTEXT,
      "unknown start menu context",
      { context = value.context }
    )
  end
  local progression = value.progression
  if type(progression) ~= "table" then
    invalidSnapshot("the snapshot must carry the progression table")
  end
  for _, field in ipairs(PROGRESSION_FIELDS) do
    if type(progression[field]) ~= "boolean" then
      invalidSnapshot("the progression boolean is required", { field = field })
    end
  end
  for key in pairs(progression) do
    local known = false
    for _, field in ipairs(PROGRESSION_FIELDS) do
      if key == field then
        known = true
      end
    end
    if not known then
      invalidSnapshot("unknown progression key", { key = key })
    end
  end
  local capabilities = value.capabilities
  if capabilities ~= nil and type(capabilities) ~= "table" then
    Errors.raise(FieldErrors.START_MENU_POLICY_INVALID_CAPABILITIES, "capabilities must be an array of application ids")
  end
  if capabilities == nil then
    invalidSnapshot("the snapshot must carry the capabilities set")
  end
  local seen = {}
  local count = 0
  for key in pairs(capabilities) do
    count = count + 1
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      Errors.raise(
        FieldErrors.START_MENU_POLICY_INVALID_CAPABILITIES,
        "capabilities must be an array of application ids"
      )
    end
  end
  if count ~= #capabilities then
    Errors.raise(FieldErrors.START_MENU_POLICY_INVALID_CAPABILITIES, "capabilities must be an array of application ids")
  end
  for index = 1, #capabilities do
    local id = capabilities[index]
    if type(id) ~= "string" or id == "" then
      Errors.raise(
        FieldErrors.START_MENU_POLICY_INVALID_CAPABILITIES,
        "capabilities must be non-empty application ids",
        { id = id }
      )
    end
    if seen[id] then
      Errors.raise(FieldErrors.START_MENU_POLICY_INVALID_CAPABILITIES, "duplicate capability id", { id = id })
    end
    seen[id] = true
  end
  return value.context, progression, seen
end

-- Whether the context mask removes an action from the built list. A gate
-- value of true inhibits unconditionally; a progression key inhibits when
-- its snapshot boolean is false.
---@param mask table
---@param key string
---@param progression table
---@return boolean
local function isInhibited(mask, key, progression)
  local gate = mask[key]
  if gate == nil then
    return false
  end
  if gate == true then
    return true
  end
  return progression[gate] == false
end

-- Builds the ordered action list for one strict snapshot. Returns exactly
-- the canonical build slots (12; the POKEGEAR slot holds special action 12
-- in the union room), each with present / vanillaEnabled / targetApplication
-- modeled separately plus the capability projections. Fresh tables per
-- call; the snapshot is never mutated.
---@param value table the strict snapshot (context, progression, capabilities)
---@return table[]
function StartMenuPolicy.build(value)
  local context, progression, capabilities = validateSnapshot(value)
  local mask = CONTEXT_MASKS[context]
  local entries = {}
  local presentCount = 0
  for _, definition in ipairs(ACTIONS) do
    local isSlot = definition.sourceAction == "pokegear"
    local action = isSlot and context == "union_room" and SPECIAL_12 or definition
    local present = not isInhibited(mask, isSlot and "pokegear" or action.sourceAction, progression)
    local vanillaEnabled = VANILLA_GATES[action.sourceAction] == nil
      or progression[VANILLA_GATES[action.sourceAction]] == true
    local targetApplication = action.targetApplication
    local capabilityAvailable = targetApplication ~= nil and capabilities[targetApplication] == true
    local entry = {
      id = action.id,
      sourceAction = action.sourceAction,
      present = present,
      vanillaEnabled = vanillaEnabled,
      targetApplication = targetApplication,
      message = action.message,
      capabilityAvailable = capabilityAvailable,
      enabled = vanillaEnabled and capabilityAvailable,
      normalVisible = present and capabilityAvailable,
      developerVisible = present,
    }
    if present then
      entry.displayPosition = action.displayPosition or presentCount
      presentCount = presentCount + 1
    end
    entries[#entries + 1] = entry
  end
  return entries
end

return StartMenuPolicy
