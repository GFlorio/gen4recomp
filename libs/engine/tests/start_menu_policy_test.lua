-- StartMenuPolicy contract tests: the pure canonical action definitions and
-- context/progression rules. The twelve-row context matrix asserts action
-- ordering, presence, vanilla enabled state, and application-capability
-- state separately. The snapshot is strict: every required key is present,
-- no `or false` defaults. Actions carry the pinned bank-0196 message refs
-- and the reserved mod-facing ids. Source evidence:
-- docs/research/start-menu-policy.md (pret/pokeheartgold 008257708).

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

local FRESH = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = false }
local FULL = { hasPokedex = true, hasStarter = true, bagUnlocked = true, hasPokegear = true }

local function snapshot(overrides)
  local value = {
    context = "normal_field",
    progression = FULL,
    capabilities = { "trainer_card" },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

-- The per-action canonical metadata contract: mod-facing id, the pinned
-- bank-0196 message ref, and the destination application id (nil when the
-- action's destination is not an application).
local EXPECTED_ACTIONS = {
  pokedex = { id = "vanilla.pokedex", message = "msg.hgss.0196.00000", targetApplication = "pokedex" },
  pokemon = { id = "vanilla.pokemon", message = "msg.hgss.0196.00001", targetApplication = "pokemon" },
  bag = { id = "vanilla.bag", message = "msg.hgss.0196.00002", targetApplication = "bag" },
  trainer_card = { id = "vanilla.trainer_card", message = "msg.hgss.0196.00003", targetApplication = "trainer_card" },
  save = { id = "vanilla.save", message = "msg.hgss.0196.00004", targetApplication = "save" },
  options = { id = "vanilla.options", message = "msg.hgss.0196.00005", targetApplication = "options" },
  running_shoes = { id = "vanilla.running_shoes", message = "msg.hgss.0196.00006", targetApplication = nil },
  ["7"] = { id = "vanilla.special_7", message = "msg.hgss.0196.00007", targetApplication = nil },
  retire = { id = "vanilla.retire", message = "msg.hgss.0196.00008", targetApplication = nil },
  ["9"] = { id = "vanilla.special_9", message = "msg.hgss.0196.00014", targetApplication = "pokegear" },
  ["10"] = { id = "vanilla.special_10", message = "msg.hgss.0196.00014", targetApplication = "pokegear" },
  pokegear = { id = "vanilla.pokegear", message = "msg.hgss.0196.00014", targetApplication = "pokegear" },
  ["12"] = { id = "vanilla.special_12", message = "msg.hgss.0196.00014", targetApplication = nil },
}

-- The build sequence (start_menu.c StartMenu_BuildActionLists): the twelve
-- emitted slots in insertion order; union_room swaps the pokegear slot for
-- special action 12 (start_menu.c:501-507).
local ORDER_NORMAL = {
  "vanilla.retire",
  "vanilla.special_7",
  "vanilla.pokedex",
  "vanilla.pokemon",
  "vanilla.bag",
  "vanilla.pokegear",
  "vanilla.trainer_card",
  "vanilla.save",
  "vanilla.options",
  "vanilla.running_shoes",
  "vanilla.special_9",
  "vanilla.special_10",
}

local ORDER_UNION = {
  "vanilla.retire",
  "vanilla.special_7",
  "vanilla.pokedex",
  "vanilla.pokemon",
  "vanilla.bag",
  "vanilla.special_12",
  "vanilla.trainer_card",
  "vanilla.save",
  "vanilla.options",
  "vanilla.running_shoes",
  "vanilla.special_9",
  "vanilla.special_10",
}

-- The CheckGot* progression gates behind vanillaEnabled: the four
-- snapshot booleans gate exactly these actions; every other action's
-- availability gate is canonically true (icon index 100, default TRUE in
-- FieldSystem_ShouldDrawStartMenuIcon, start_menu.c:535-556).
local VANILLA_GATES = {
  pokedex = "hasPokedex",
  pokemon = "hasStarter",
  bag = "bagUnlocked",
  pokegear = "hasPokegear",
}

local function entryById(entries, id)
  for _, entry in ipairs(entries) do
    if entry.id == id then
      return entry
    end
  end
  error("no entry with id " .. id)
end

-- The context matrix: the twelve rows. The five normal-field rows are
-- progression states; the seven special contexts use full progression so
-- their masks are asserted against the progression gates separately.
local MATRIX = {
  fresh_game = {
    context = "normal_field",
    progression = FRESH,
    present = {
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  starter_obtained = {
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = true, bagUnlocked = false, hasPokegear = false },
    present = {
      "vanilla.pokemon",
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  pokedex_obtained = {
    context = "normal_field",
    progression = { hasPokedex = true, hasStarter = false, bagUnlocked = false, hasPokegear = false },
    present = {
      "vanilla.pokedex",
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  bag_unlocked = {
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = true, hasPokegear = false },
    present = {
      "vanilla.bag",
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  pokegear_obtained = {
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = true },
    present = {
      "vanilla.pokegear",
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  amity_square = {
    context = "amity_square",
    progression = FULL,
    present = {
      "vanilla.pokedex",
      "vanilla.pokegear",
      "vanilla.trainer_card",
      "vanilla.save",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  safari = {
    context = "safari",
    progression = FULL,
    present = {
      "vanilla.retire",
      "vanilla.pokedex",
      "vanilla.pokemon",
      "vanilla.bag",
      "vanilla.pokegear",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  bug_contest = {
    context = "bug_contest",
    progression = FULL,
    present = {
      "vanilla.retire",
      "vanilla.pokedex",
      "vanilla.pokemon",
      "vanilla.pokegear",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  pal_park = {
    context = "pal_park",
    progression = FULL,
    present = {
      "vanilla.retire",
      "vanilla.pokedex",
      "vanilla.pokemon",
      "vanilla.pokegear",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  battle_tower_partner_room = {
    context = "battle_tower_partner_room",
    progression = FULL,
    present = {
      "vanilla.pokemon",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  colosseum = {
    context = "colosseum",
    progression = FULL,
    present = {
      "vanilla.pokemon",
      "vanilla.bag",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
  union_room = {
    context = "union_room",
    progression = FULL,
    present = {
      "vanilla.special_7",
      "vanilla.pokedex",
      "vanilla.pokemon",
      "vanilla.bag",
      "vanilla.special_12",
      "vanilla.trainer_card",
      "vanilla.options",
      "vanilla.running_shoes",
      "vanilla.special_9",
      "vanilla.special_10",
    },
  },
}

-- The context matrix, asserting ordering, presence, vanilla enabled state,
-- and the capability projections separately for every row.
function T.tests.the_context_matrix_asserts_ordering_presence_vanilla_and_capability()
  for name, row in pairs(MATRIX) do
    local expectedOrder = row.context == "union_room" and ORDER_UNION or ORDER_NORMAL
    local entries = StartMenuPolicy.build(snapshot({ context = row.context, progression = row.progression }))

    local ids = {}
    for _, entry in ipairs(entries) do
      ids[#ids + 1] = entry.id
    end
    Assert.deepEqual(ids, expectedOrder, name .. " ordering")

    local expectedPresent = {}
    for _, id in ipairs(row.present) do
      expectedPresent[id] = true
    end

    local presentCount = 0
    for _, entry in ipairs(entries) do
      local expected =
        assert(EXPECTED_ACTIONS[entry.sourceAction], name .. " sourceAction " .. tostring(entry.sourceAction))
      Assert.equal(entry.id, expected.id, name .. " id for " .. entry.sourceAction)
      Assert.equal(entry.message, expected.message, name .. " message ref for " .. entry.sourceAction)
      Assert.equal(
        entry.targetApplication,
        expected.targetApplication,
        name .. " targetApplication for " .. entry.sourceAction
      )

      local isPresent = expectedPresent[entry.id] == true
      Assert.equal(entry.present, isPresent, name .. " presence of " .. entry.id)

      local gate = VANILLA_GATES[entry.sourceAction]
      local expectedVanilla = gate == nil or row.progression[gate] == true
      Assert.equal(entry.vanillaEnabled, expectedVanilla, name .. " vanillaEnabled of " .. entry.id)

      local expectedCapability = entry.targetApplication ~= nil and entry.targetApplication == "trainer_card"
      Assert.equal(entry.capabilityAvailable, expectedCapability, name .. " capabilityAvailable of " .. entry.id)
      Assert.equal(
        entry.enabled,
        entry.vanillaEnabled and entry.capabilityAvailable,
        name .. " enabled of " .. entry.id
      )
      Assert.equal(
        entry.normalVisible,
        isPresent and entry.capabilityAvailable,
        name .. " normalVisible of " .. entry.id
      )
      Assert.equal(entry.developerVisible, isPresent, name .. " developerVisible of " .. entry.id)

      local expectedPosition
      if entry.sourceAction == "9" then
        expectedPosition = 7
      elseif entry.sourceAction == "10" then
        expectedPosition = 8
      elseif isPresent then
        expectedPosition = presentCount
      end
      Assert.equal(entry.displayPosition, expectedPosition, name .. " displayPosition of " .. entry.id)
      if isPresent then
        presentCount = presentCount + 1
      end
    end
  end
end

-- The strict snapshot: every required key is present, no `or false`
-- defaults; a missing boolean is a rejection, not a plausible default.
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
    local value = snapshot()
    value.context = nil
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = snapshot()
    value.progression = nil
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local progression = { hasPokedex = true, hasStarter = true, bagUnlocked = nil, hasPokegear = true }
    StartMenuPolicy.build(snapshot({ progression = progression }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local progression = { hasPokedex = true, hasStarter = true, hasPokegear = true }
    StartMenuPolicy.build(snapshot({ progression = progression }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local progression = { hasPokedex = "yes", hasStarter = true, bagUnlocked = true, hasPokegear = true }
    StartMenuPolicy.build(snapshot({ progression = progression }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local progression =
      { hasPokedex = true, hasStarter = true, bagUnlocked = true, hasPokegear = true, hasPokedexx = true }
    StartMenuPolicy.build(snapshot({ progression = progression }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = snapshot()
    value.extra = true
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_INVALID_SNAPSHOT", function()
    local value = snapshot()
    value.capabilities = nil
    StartMenuPolicy.build(value)
  end)
  throwsCode("START_MENU_POLICY_UNKNOWN_CONTEXT", function()
    StartMenuPolicy.build(snapshot({ context = "safari_zone" }))
  end)
  throwsCode("START_MENU_POLICY_UNKNOWN_CONTEXT", function()
    StartMenuPolicy.build(snapshot({ context = "route_1" }))
  end)
end

function T.tests.strict_snapshot_rejects_malformed_capabilities()
  throwsCode("START_MENU_POLICY_INVALID_CAPABILITIES", function()
    StartMenuPolicy.build(snapshot({ capabilities = "trainer_card" }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_CAPABILITIES", function()
    StartMenuPolicy.build(snapshot({ capabilities = { 42 } }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_CAPABILITIES", function()
    StartMenuPolicy.build(snapshot({ capabilities = { "" } }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_CAPABILITIES", function()
    StartMenuPolicy.build(snapshot({ capabilities = { "trainer_card", "trainer_card" } }))
  end)
  throwsCode("START_MENU_POLICY_INVALID_CAPABILITIES", function()
    local sparse = {} ---@type table
    sparse[1] = "trainer_card"
    sparse[3] = "pokedex"
    StartMenuPolicy.build(snapshot({ capabilities = sparse }))
  end)
  local entries = StartMenuPolicy.build(snapshot({ capabilities = {} }))
  Assert.equal(#entries, 12, "an empty capability set still builds the canonical list")
end

-- The capability split: present/vanillaEnabled/targetApplication are
-- independent; the injected capability set flips only the capability
-- projections.
function T.tests.the_capability_set_flips_only_the_capability_projections()
  local base = StartMenuPolicy.build(snapshot())
  local grown = StartMenuPolicy.build(
    snapshot({ capabilities = { "trainer_card", "pokedex", "bag", "pokegear", "save", "options", "pokemon" } })
  )

  local pokedexBase = entryById(base, "vanilla.pokedex")
  local pokedexGrown = entryById(grown, "vanilla.pokedex")
  Assert.equal(pokedexBase.present, true)
  Assert.equal(pokedexBase.vanillaEnabled, true)
  Assert.equal(pokedexBase.capabilityAvailable, false, "pokedex is not in the injected set")
  Assert.equal(pokedexBase.enabled, false)
  Assert.equal(pokedexBase.normalVisible, false, "capability-missing actions hide in normal builds")
  Assert.equal(pokedexBase.developerVisible, true, "capability-missing actions stay visible in developer builds")
  Assert.equal(pokedexGrown.capabilityAvailable, true, "adding the application to the set flips capability")
  Assert.equal(pokedexGrown.enabled, true)
  Assert.equal(pokedexGrown.normalVisible, true)
  Assert.equal(pokedexGrown.present, true, "presence is unaffected by the capability set")
  Assert.equal(pokedexGrown.vanillaEnabled, true, "vanillaEnabled is unaffected by the capability set")
  Assert.equal(pokedexGrown.developerVisible, true)

  local bagBase = entryById(base, "vanilla.bag")
  Assert.equal(bagBase.capabilityAvailable, false)
  local bagGrown = entryById(grown, "vanilla.bag")
  Assert.equal(bagGrown.capabilityAvailable, true)

  local shoesBase = entryById(base, "vanilla.running_shoes")
  Assert.equal(shoesBase.targetApplication, nil, "running shoes has no application destination")
  Assert.equal(shoesBase.capabilityAvailable, false)
  Assert.equal(shoesBase.present, true)
  Assert.equal(shoesBase.enabled, false)
  Assert.equal(shoesBase.normalVisible, false)
  Assert.equal(shoesBase.developerVisible, true)
end

-- The present-vs-unavailable distinction: in Safari the mask never
-- inhibits the progression-gated actions, so a fresh game's Safari menu
-- still lists Pokédex/Pokémon/Bag/Pokégear as present-but-unavailable.
function T.tests.safari_with_fresh_progression_lists_present_but_unavailable_actions()
  local entries = StartMenuPolicy.build(snapshot({ context = "safari", progression = FRESH }))
  local pokedex = entryById(entries, "vanilla.pokedex")
  Assert.equal(pokedex.present, true, "the Safari mask does not inhibit pokedex")
  Assert.equal(pokedex.vanillaEnabled, false, "the availability gate still applies")
  Assert.equal(pokedex.enabled, false)
  Assert.equal(pokedex.normalVisible, false)
  Assert.equal(pokedex.developerVisible, true)
  local pokegear = entryById(entries, "vanilla.pokegear")
  Assert.equal(pokegear.present, true)
  Assert.equal(pokegear.vanillaEnabled, false)
  local save = entryById(entries, "vanilla.save")
  Assert.equal(save.present, false, "the Safari mask inhibits save")
  Assert.equal(save.developerVisible, false, "an absent action is not developer-visible either")
  Assert.equal(save.displayPosition, nil)
end

-- Vanilla Options stays a reserved canonical action, never redirected to a
-- project destination.
function T.tests.vanilla_options_stays_reserved_and_capability_gated()
  local entries = StartMenuPolicy.build(snapshot())
  local options = entryById(entries, "vanilla.options")
  Assert.equal(options.id, "vanilla.options")
  Assert.equal(options.targetApplication, "options", "options keeps its canonical destination")
  Assert.equal(options.present, true)
  Assert.equal(options.vanillaEnabled, true)
  Assert.equal(options.capabilityAvailable, false, "options is not implemented this sprint")
  Assert.equal(options.enabled, false)
  Assert.equal(options.normalVisible, false)
  Assert.equal(options.developerVisible, true)
end

-- The reserved mod-facing ids are exactly the eight declared ids.
function T.tests.the_reserved_ids_and_context_names_are_the_pinned_sets()
  Assert.deepEqual(StartMenuPolicy.RESERVED_IDS, {
    "vanilla.pokedex",
    "vanilla.pokemon",
    "vanilla.bag",
    "vanilla.pokegear",
    "vanilla.trainer_card",
    "vanilla.save",
    "vanilla.options",
    "vanilla.running_shoes",
  })
  Assert.deepEqual(StartMenuPolicy.CONTEXTS, {
    "normal_field",
    "amity_square",
    "safari",
    "bug_contest",
    "pal_park",
    "battle_tower_partner_room",
    "colosseum",
    "union_room",
  })
  local entries = StartMenuPolicy.build(snapshot())
  for _, entry in ipairs(entries) do
    Assert.isTrue(
      entry.id:sub(1, #"vanilla.") == "vanilla.",
      "every canonical action id is mod-visible under vanilla.*"
    )
  end
end

-- build is a pure projection: it never mutates the snapshot and returns
-- fresh entry tables per call.
function T.tests.build_does_not_mutate_the_snapshot_and_returns_fresh_entries()
  local value = snapshot()
  local before = snapshot()
  local first = StartMenuPolicy.build(value)
  first[1].present = not first[1].present
  local second = StartMenuPolicy.build(value)
  Assert.deepEqual(value, before, "the snapshot is untouched")
  Assert.isTrue(first[1] ~= second[1], "each call returns fresh entry tables")
  Assert.equal(second[1].present, false, "the mutation of the first result did not leak into the second")
  Assert.equal(second[1].message, "msg.hgss.0196.00008", "fresh entries carry the same metadata")
end

return T
