-- FieldApplicationIds contract tests: the one domain-owned application-id
-- table shared by the Start Menu policy (targetApplication), the application
-- catalogue, and host dispatch. The policy must draw every destination id it
-- routes from this table -- no raw protocol strings cross the module
-- boundary -- and the table carries exactly the implemented destination set.

local Assert = require("tests.support.Assert")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")

local T = {
  tests = {},
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
  Assert.deepEqual(ids, { "bag", "options", "pokedex", "pokegear", "pokemon", "trainer_card" })
end

-- Every destination the policy routes is drawn from the centralized table:
-- with full source facts, every "application" action's targetApplication is
-- a member of the FieldApplicationIds set; non-application actions have no
-- target.
function T.tests.policy_routes_only_centralized_application_ids()
  local actions = StartMenuPolicy.actions(FULL_FACTS)
  local applicationActions = 0
  for _, action in ipairs(actions) do
    if action.actionKind == "application" then
      applicationActions = applicationActions + 1
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
    else
      Assert.isNil(action.targetApplication, "a non-application action has no target application")
    end
  end
  Assert.equal(applicationActions, 8, "the implemented applications plus the two pokegear specials route somewhere")
end

return T
