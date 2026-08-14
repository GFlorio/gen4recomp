-- Idle-boundary open eligibility for the Start Menu: the pure gate the
-- session consults before an open edge may acquire focus or movement pause.
-- The snapshot is strict (every required key present, no `or false` defaults)
-- and the decision contract carries the menu-wins-over-action edge rule: an
-- eligible menu open must clear a simultaneously arriving Action edge so the
-- same tick cannot also trigger the facing interaction, while an ineligible
-- open edge acquires nothing and leaves the Action edge untouched.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local StartMenuEligibility = require("libs.engine.src.StartMenuEligibility")

local T = {}

local function eligibleSnapshot()
  return {
    playerMotion = "idle",
    transitionIdle = true,
    dialogueModal = false,
    signpostModal = false,
    scriptMenuModal = false,
    contextChoiceActive = false,
    applicationActive = false,
    foregroundScript = false,
    movementLocked = false,
  }
end

function T.a_settled_field_boundary_is_eligible()
  Assert.isTrue(StartMenuEligibility.evaluate(eligibleSnapshot()))
end

function T.every_occupancy_condition_blocks_eligibility()
  local conditions = {
    player_moving = { playerMotion = "walking" },
    player_climbing = { playerMotion = "climbing" },
    transition_active = { transitionIdle = false },
    dialogue_open = { dialogueModal = true },
    signpost_presented = { signpostModal = true },
    script_menu_open = { scriptMenuModal = true },
    context_choice_open = { contextChoiceActive = true },
    application_active = { applicationActive = true },
    foreground_script_owns_field = { foregroundScript = true },
    movement_locked = { movementLocked = true },
  }
  for name, mutation in pairs(conditions) do
    local snapshot = eligibleSnapshot()
    for key, value in pairs(mutation) do
      snapshot[key] = value
    end
    Assert.isFalse(
      StartMenuEligibility.evaluate(snapshot),
      "the " .. name .. " condition must block the open eligibility"
    )
  end
end

function T.eligibility_is_a_pure_boolean_and_acquires_nothing()
  local snapshot = eligibleSnapshot()
  Assert.equal(StartMenuEligibility.evaluate(snapshot), true)
  Assert.deepEqual(snapshot, eligibleSnapshot(), "evaluating eligibility must not mutate the snapshot")
  Assert.throws(function()
    StartMenuEligibility.evaluate(setmetatable({}, {
      __index = function()
        error("the eligibility snapshot must never fall back to defaults", 0)
      end,
    }))
  end, "a default-falling snapshot must be rejected, never defaulted")
end

function T.missing_or_unknown_snapshot_keys_are_rejected()
  local throwsCode = function(fn, expected)
    local err = Assert.throws(fn)
    local raised = Errors.is(err) and err.code or tostring(err)
    Assert.equal(raised, expected, "expected " .. expected .. ", got " .. raised)
  end
  for key in pairs(eligibleSnapshot()) do
    local snapshot = eligibleSnapshot()
    snapshot[key] = nil
    throwsCode(function()
      StartMenuEligibility.evaluate(snapshot)
    end, "START_MENU_ELIGIBILITY_INVALID_SNAPSHOT")
  end
  local unknown = eligibleSnapshot()
  unknown.someFutureField = false
  throwsCode(function()
    StartMenuEligibility.evaluate(unknown)
  end, "START_MENU_ELIGIBILITY_INVALID_SNAPSHOT")
  local badType = eligibleSnapshot()
  badType.transitionIdle = 1
  throwsCode(function()
    StartMenuEligibility.evaluate(badType)
  end, "START_MENU_ELIGIBILITY_INVALID_SNAPSHOT")
  local badMotion = eligibleSnapshot()
  badMotion.playerMotion = "flying"
  throwsCode(function()
    StartMenuEligibility.evaluate(badMotion)
  end, "START_MENU_ELIGIBILITY_INVALID_SNAPSHOT")
  local notASnapshot = "not a snapshot" ---@type any
  throwsCode(function()
    StartMenuEligibility.evaluate(notASnapshot)
  end, "START_MENU_ELIGIBILITY_INVALID_SNAPSHOT")
end

function T.an_eligible_menu_edge_wins_over_a_simultaneous_action_edge()
  local decision = StartMenuEligibility.decide(eligibleSnapshot(), { menuPressed = true, actionPressed = true })
  Assert.equal(decision.menu, "open", "the menu must open at the eligible boundary")
  Assert.equal(decision.action, "clear", "the winning menu must clear the simultaneous Action edge")
end

function T.an_eligible_menu_edge_without_an_action_edge_keeps_nothing()
  local decision = StartMenuEligibility.decide(eligibleSnapshot(), { menuPressed = true })
  Assert.equal(decision.menu, "open")
  Assert.equal(decision.action, "keep")
end

function T.an_ineligible_menu_edge_acquires_nothing_and_keeps_the_action_edge()
  local snapshot = eligibleSnapshot()
  snapshot.dialogueModal = true
  local decision = StartMenuEligibility.decide(snapshot, { menuPressed = true, actionPressed = true })
  Assert.equal(decision.menu, "ignore", "an ineligible open edge must acquire nothing")
  Assert.equal(decision.action, "keep", "an ineligible open edge must not disturb the Action edge")
end

function T.without_a_menu_edge_the_decision_ignores_the_menu()
  local decision = StartMenuEligibility.decide(eligibleSnapshot(), { menuPressed = false, actionPressed = true })
  Assert.equal(decision.menu, "ignore")
  Assert.equal(decision.action, "keep")
end

function T.decide_validates_its_snapshot_and_edges()
  Assert.throws(function()
    StartMenuEligibility.decide({}, { menuPressed = true })
  end)
  Assert.throws(function()
    StartMenuEligibility.decide(eligibleSnapshot(), {})
  end)
  local badEdge = "yes" ---@type any
  Assert.throws(function()
    StartMenuEligibility.decide(eligibleSnapshot(), { menuPressed = badEdge })
  end)
end

return { tests = T }
