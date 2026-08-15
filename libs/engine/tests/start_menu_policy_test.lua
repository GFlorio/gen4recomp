-- StartMenuPolicy contract tests: the pure canonical action definitions and
-- the normal-field progression rules for the implemented field context. The
-- strict snapshot is the seven unlock facts the runtime reads from the
-- event-state flags; every action's output separates list presence (the
-- source inhibit masks, start_menu.c:288-331) from the gameplay unlock gate
-- (the CheckGot*/FLAG_GOT_* availability checks, start_menu.c:535-556), plus
-- the canonical display position. No capability or product-mode projection
-- lives here: the runtime intersects the registered destination
-- applications. Source evidence: docs/research/start-menu-policy.md
-- (pret/pokeheartgold 008257708).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")

local T = {
  tests = {},
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

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

-- The canonical build order (StartMenu_BuildActionLists, start_menu.c:483-523)
-- with each action's destination application id.
local EXPECTED_ACTIONS = {
  { id = "vanilla.retire", targetApplication = nil },
  { id = "vanilla.special_7", targetApplication = nil },
  { id = "vanilla.pokedex", targetApplication = "pokedex" },
  { id = "vanilla.pokemon", targetApplication = "pokemon" },
  { id = "vanilla.bag", targetApplication = "bag" },
  { id = "vanilla.pokegear", targetApplication = "pokegear" },
  { id = "vanilla.trainer_card", targetApplication = "trainer_card" },
  { id = "vanilla.save", targetApplication = "save" },
  { id = "vanilla.options", targetApplication = "options" },
  { id = "vanilla.running_shoes", targetApplication = nil },
  { id = "vanilla.special_9", targetApplication = "pokegear" },
  { id = "vanilla.special_10", targetApplication = "pokegear" },
}

local function entryById(entries, id)
  for _, entry in ipairs(entries) do
    if entry.id == id then
      return entry
    end
  end
  error("no entry with id " .. id)
end

-- Full progression: every action except RETIRE and the removed feature 7 is
-- present; the four progression-gated actions and the three unlock-flag
-- actions are unlocked; display positions are dense 0..6 then the
-- unconditionally written Pokégear-family positions 7/8 (special 9
-- overwrites whatever landed at 7 -- running shoes -- in the display array).
function T.tests.full_progression_builds_the_canonical_list()
  local entries = StartMenuPolicy.build(facts())
  Assert.equal(#entries, 12, "the canonical build emits the twelve source slots")
  for index, expected in ipairs(EXPECTED_ACTIONS) do
    local entry = entries[index]
    Assert.equal(entry.id, expected.id, "slot " .. index .. " id")
    Assert.equal(entry.targetApplication, expected.targetApplication, "slot " .. index .. " destination")
  end
  local absent = { "vanilla.retire", "vanilla.special_7" }
  for _, id in ipairs(absent) do
    Assert.equal(entryById(entries, id).present, false, id .. " is unconditionally inhibited")
  end
  local expectedPositions = {
    ["vanilla.pokedex"] = 0,
    ["vanilla.pokemon"] = 1,
    ["vanilla.bag"] = 2,
    ["vanilla.pokegear"] = 3,
    ["vanilla.trainer_card"] = 4,
    ["vanilla.save"] = 5,
    ["vanilla.options"] = 6,
    ["vanilla.running_shoes"] = 7,
    ["vanilla.special_9"] = 7,
    ["vanilla.special_10"] = 8,
  }
  for id, position in pairs(expectedPositions) do
    Assert.equal(entryById(entries, id).displayPosition, position, id .. " display position")
  end
  for _, id in ipairs({
    "vanilla.pokedex",
    "vanilla.pokemon",
    "vanilla.bag",
    "vanilla.pokegear",
    "vanilla.trainer_card",
    "vanilla.save",
    "vanilla.options",
  }) do
    Assert.equal(entryById(entries, id).unlocked, true, id .. " is unlocked at full progression")
  end
  for _, id in ipairs({ "vanilla.running_shoes", "vanilla.special_9", "vanilla.special_10" }) do
    Assert.equal(entryById(entries, id).unlocked, true, id .. " has no gameplay gate")
  end
end

-- A fresh game: no progression and no unlock flags. The unlock-flag actions
-- stay present (the source masks do not inhibit them) but locked; the
-- display positions stay dense over the present entries.
function T.tests.fresh_game_lists_present_but_locked_unlock_actions()
  local entries = StartMenuPolicy.build(facts({
    hasPokedex = false,
    hasStarter = false,
    bagUnlocked = false,
    hasPokegear = false,
    trainerCardUnlocked = false,
    saveUnlocked = false,
    optionsUnlocked = false,
  }))
  local present = {}
  local positions = {}
  for _, entry in ipairs(entries) do
    if entry.present then
      present[#present + 1] = entry.id
      positions[entry.id] = entry.displayPosition
    end
  end
  Assert.deepEqual(present, {
    "vanilla.trainer_card",
    "vanilla.save",
    "vanilla.options",
    "vanilla.running_shoes",
    "vanilla.special_9",
    "vanilla.special_10",
  })
  Assert.deepEqual(positions, {
    ["vanilla.trainer_card"] = 0,
    ["vanilla.save"] = 1,
    ["vanilla.options"] = 2,
    ["vanilla.running_shoes"] = 3,
    ["vanilla.special_9"] = 7,
    ["vanilla.special_10"] = 8,
  })
  for _, id in ipairs({ "vanilla.trainer_card", "vanilla.save", "vanilla.options" }) do
    Assert.equal(entryById(entries, id).unlocked, false, id .. " is locked until its flag is set")
  end
  Assert.equal(entryById(entries, "vanilla.pokedex").present, false, "no progression means no pokedex entry")
  Assert.equal(entryById(entries, "vanilla.pokedex").unlocked, false)
end

-- Presence and the unlock gate are independent: a progression-gated action
-- is present exactly when its progression fact is true, and its unlock gate
-- follows the same fact; the flag-gated actions are present regardless.
function T.tests.presence_and_unlock_are_independent_projections()
  local entries = StartMenuPolicy.build(facts({
    hasStarter = false,
    trainerCardUnlocked = true,
  }))
  local pokemon = entryById(entries, "vanilla.pokemon")
  Assert.equal(pokemon.present, false, "pokemon is inhibited without a starter")
  Assert.equal(pokemon.unlocked, false)
  local card = entryById(entries, "vanilla.trainer_card")
  Assert.equal(card.present, true, "trainer card is never mask-inhibited")
  Assert.equal(card.unlocked, true, "its flag flips only the unlock gate")
  Assert.equal(card.displayPosition, 3, "the present list stays dense over pokedex/bag/pokegear")
  local save = entryById(entries, "vanilla.save")
  Assert.equal(save.unlocked, true, "the save flag is on")
  Assert.equal(save.displayPosition, 4)
end

-- The output carries exactly the declared fields: no message ref, no
-- capability or product-mode projections, no enabled/visible state.
function T.tests.output_carries_only_the_declared_fields()
  local entries = StartMenuPolicy.build(facts())
  for _, entry in ipairs(entries) do
    local keys = {}
    for key in pairs(entry) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    local expected = { "id", "present", "unlocked" }
    if entry.targetApplication ~= nil then
      table.insert(expected, "targetApplication")
    end
    if entry.present then
      table.insert(expected, "displayPosition")
    end
    table.sort(expected)
    Assert.deepEqual(keys, expected, "entry " .. entry.id .. " carries only the declared fields")
  end
end

-- The strict snapshot: every required fact is present, no `or false`
-- defaults; a missing or malformed boolean is a rejection, not a plausible
-- default.
function T.tests.strict_snapshot_rejects_missing_and_malformed_input()
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = nil ---@type any
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = "normal_field" ---@type any
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = facts()
    value.hasPokedex = nil
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = facts()
    value.bagUnlocked = "yes"
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = facts()
    value.hasPokedexx = true
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = facts()
    value.context = "normal_field"
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = facts()
    value.capabilities = { "trainer_card" }
    StartMenuPolicy.build(value)
  end)
end

-- build is a pure projection: it never mutates the snapshot and returns
-- fresh entry tables per call.
function T.tests.build_does_not_mutate_the_snapshot_and_returns_fresh_entries()
  local value = facts()
  local before = facts()
  local first = StartMenuPolicy.build(value)
  first[1].present = not first[1].present
  local second = StartMenuPolicy.build(value)
  Assert.deepEqual(value, before, "the snapshot is untouched")
  Assert.isTrue(first[1] ~= second[1], "each call returns fresh entry tables")
  Assert.equal(second[1].present, false, "the mutation of the first result did not leak into the second")
end

return T
