-- FieldApplicationIds contract tests: the one domain-owned application-id
-- table shared by the Start Menu policy (targetApplication), the application
-- catalogue, and host dispatch. The policy must draw every destination id it
-- routes from this table -- no raw protocol strings cross the module
-- boundary -- and the table carries exactly the implemented destination set.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.engine.src.FieldApplicationIds")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")

local T = {
  tests = {},
}

local ALL_APPLICATIONS = {
  pokedex = true,
  pokemon = true,
  bag = true,
  pokegear = true,
  trainer_card = true,
  save = true,
  options = true,
}

local FULL_FACTS = {
  hasPokedex = true,
  hasStarter = true,
  bagUnlocked = true,
  hasPokegear = true,
  trainerCardUnlocked = true,
  saveUnlocked = true,
  optionsUnlocked = true,
}

function T.tests.the_id_table_carries_exactly_the_implemented_destination_set()
  local ids = {}
  for _, id in pairs(FieldApplicationIds) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  Assert.deepEqual(ids, { "bag", "options", "pokedex", "pokegear", "pokemon", "save", "trainer_card" })
end

-- Every destination the policy routes is drawn from the centralized table:
-- with all applications registered, the final action list's targetApplication
-- values are exactly the FieldApplicationIds set.
function T.tests.policy_routes_only_centralized_application_ids()
  local actions = StartMenuPolicy.availableActions(FULL_FACTS, function(applicationId)
    return ALL_APPLICATIONS[applicationId] == true
  end)
  Assert.equal(#actions, 9, "the seven application actions plus the two pokegear specials are interactive")
  for _, action in ipairs(actions) do
    local centralized = false
    for _, id in pairs(FieldApplicationIds) do
      if id == action.targetApplication then
        centralized = true
      end
    end
    Assert.isTrue(
      centralized,
      "the policy must route only centralized application ids, got: " .. tostring(action.targetApplication)
    )
  end
end

return T
