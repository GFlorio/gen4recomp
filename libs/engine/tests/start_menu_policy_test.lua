-- StartMenuPolicy contract tests: the pure canonical action definitions and
-- the normal-field progression rules for the implemented field context. The
-- facts are the seven unlock values the runtime reads from the event-state
-- flags (the CheckGot*/FLAG_GOT_* gates, start_menu.c:535-556) as ordinary
-- internal data; each source action still separates list presence (the
-- source inhibit masks, start_menu.c:288-331) from the gameplay unlock gate.
-- availableActions returns the final interactive list the runtime needs:
-- every source action is processed in canonical insertion order so
-- present-but-unimplemented actions keep their display positions, and an
-- entry is interactive exactly when present AND unlocked AND its destination
-- application is registered (the hasApplication predicate). Source evidence:
-- docs/research/start-menu-policy.md (pret/pokeheartgold 008257708).

local Assert = require("tests.support.Assert")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")

local T = {
  tests = {},
}

local FRESH = {
  hasPokedex = false,
  hasStarter = false,
  bagUnlocked = false,
  hasPokegear = false,
  trainerCardUnlocked = false,
  saveUnlocked = false,
  optionsUnlocked = false,
}

local function fullFacts()
  return {
    hasPokedex = true,
    hasStarter = true,
    bagUnlocked = true,
    hasPokegear = true,
    trainerCardUnlocked = true,
    saveUnlocked = true,
    optionsUnlocked = true,
  }
end

local function facts(overrides)
  local value = fullFacts()
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local ALL_APPLICATIONS = {
  pokedex = true,
  pokemon = true,
  bag = true,
  pokegear = true,
  trainer_card = true,
  save = true,
  options = true,
}

local function available(factSnapshot, applications)
  return StartMenuPolicy.availableActions(factSnapshot, function(applicationId)
    return applications[applicationId] == true
  end)
end

local function actionById(actions, id)
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- Full progression with every destination registered: the seven application
-- actions plus the unconditionally written Pokégear-family entries 9/10 are
-- interactive, display positions are dense over the present entries
-- (0..6 then 7/8 for the specials), and actions without a destination
-- (RETIRE, feature 7, running shoes) never appear.
function T.tests.full_progression_returns_the_final_interactive_list()
  local actions = available(facts(), ALL_APPLICATIONS)
  Assert.deepEqual(actions, {
    { id = "vanilla.pokedex", targetApplication = "pokedex", displayPosition = 0 },
    { id = "vanilla.pokemon", targetApplication = "pokemon", displayPosition = 1 },
    { id = "vanilla.bag", targetApplication = "bag", displayPosition = 2 },
    { id = "vanilla.pokegear", targetApplication = "pokegear", displayPosition = 3 },
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 4 },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 5 },
    { id = "vanilla.options", targetApplication = "options", displayPosition = 6 },
    { id = "vanilla.special_9", targetApplication = "pokegear", displayPosition = 7 },
    { id = "vanilla.special_10", targetApplication = "pokegear", displayPosition = 8 },
  })
end

-- A fresh game with no destinations registered: nothing is interactive.
function T.tests.fresh_game_with_no_registered_destinations_is_empty()
  Assert.deepEqual(available(FRESH, {}), {})
end

-- Present-but-unimplemented source actions keep their canonical display
-- positions ahead of the implemented destinations: with the bag/pokegear
-- progression missing, the trainer card sits at position 2 behind the
-- present pokedex/pokemon entries even when only the card and save are
-- registered.
function T.tests.unimplemented_present_actions_keep_display_positions()
  local actions = available(
    facts({
      bagUnlocked = false,
      hasPokegear = false,
      optionsUnlocked = false,
    }),
    {
      trainer_card = true,
      save = true,
    }
  )
  Assert.deepEqual(actions, {
    { id = "vanilla.trainer_card", targetApplication = "trainer_card", displayPosition = 2 },
    { id = "vanilla.save", targetApplication = "save", displayPosition = 3 },
  })
end

-- The unlock gate is part of the final filter: a present but locked action
-- is not interactive even when its destination is registered, and the
-- positions of the interactive actions stay dense over the present list.
function T.tests.present_but_locked_actions_stay_inactive()
  local actions = available(facts({ trainerCardUnlocked = false }), ALL_APPLICATIONS)
  Assert.isNil(actionById(actions, "vanilla.trainer_card"), "a locked action must not be interactive")
  local save = assert(actionById(actions, "vanilla.save"))
  Assert.equal(save.displayPosition, 5, "positions stay dense over the present list, not the interactive list")
end

-- Presence gates still follow the source inhibit masks: a progression-gated
-- action without its progression fact is neither present nor interactive,
-- and the positions of the later actions compress over the present list.
function T.tests.presence_gates_follow_the_source_inhibit_masks()
  local actions = available(facts({ hasPokedex = false }), ALL_APPLICATIONS)
  Assert.isNil(actionById(actions, "vanilla.pokedex"), "an inhibited action is not interactive")
  Assert.equal(assert(actionById(actions, "vanilla.pokemon")).displayPosition, 0)
  Assert.equal(assert(actionById(actions, "vanilla.trainer_card")).displayPosition, 3)
end

-- The output records carry exactly the declared fields: id, destination,
-- and display position. No present/unlocked projection, no sourceAction.
function T.tests.output_carries_only_the_declared_fields()
  for _, action in ipairs(available(facts(), ALL_APPLICATIONS)) do
    local keys = {}
    for key in pairs(action) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    Assert.deepEqual(keys, { "displayPosition", "id", "targetApplication" }, "action " .. action.id)
  end
end

-- The facts are ordinary internal data: the seven required booleans are
-- asserted (a missing or malformed fact is a programming fault), but
-- additional keys are tolerated and never read.
function T.tests.facts_are_internal_data_with_asserted_booleans()
  Assert.throws(function()
    local value = facts()
    value.hasPokedex = nil
    available(value, ALL_APPLICATIONS)
  end)
  Assert.throws(function()
    local value = facts()
    value.bagUnlocked = "yes"
    available(value, ALL_APPLICATIONS)
  end)
  Assert.throws(function()
    available(nil, ALL_APPLICATIONS)
  end)
  local withExtras = facts()
  withExtras.context = "normal_field"
  withExtras.capabilities = { "trainer_card" }
  Assert.equal(#available(withExtras, ALL_APPLICATIONS), 9, "unknown fact keys are ordinary data, not errors")
end

-- availableActions is a pure projection: it never mutates the facts or the
-- predicate state and returns fresh records per call.
function T.tests.available_actions_is_pure()
  local value = facts()
  local before = facts()
  local seen = {}
  local first = StartMenuPolicy.availableActions(value, function(applicationId)
    seen[applicationId] = true
    return ALL_APPLICATIONS[applicationId] == true
  end)
  first[1].displayPosition = 999
  local second = available(value, ALL_APPLICATIONS)
  Assert.deepEqual(value, before, "the facts are untouched")
  Assert.equal(second[1].displayPosition, 0, "the mutation of the first result did not leak into the second")
  Assert.equal(seen.pokedex, true, "the predicate is consulted for every application action")
end

return T
