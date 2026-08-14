-- StartMenuRegistry contract tests: the per-runtime mod action catalogue is
-- built then sealed before the first menu open. Registration validates ids/
-- labels/icons/targets/placements, rejects duplicates and the reserved
-- vanilla.* ids; seal resolves before/after constraints against the full
-- semantic canonical order deterministically (rejecting unknown anchors and
-- placement cycles with diagnostics naming both actions); compose merges the
-- mod entries into the policy build output and raises the structured
-- START_MENU_CAPACITY_EXCEEDED diagnostic when the composed visible list
-- exceeds the generated slot capacity.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")
local StartMenuRegistry = require("libs.engine.src.StartMenuRegistry")

local T = {
  tests = {},
}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

local CANONICAL_IDS = StartMenuPolicy.canonicalOrder()

local function fullDescriptor(overrides)
  local value = {
    id = "my_mod.quest_log",
    label = "msg.my_mod.quest_log",
    icon = "asset.my_mod.quest_log_icon",
    targetApplication = "my_mod.quest_log",
    placement = { after = "vanilla.trainer_card" },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function newRegistry(descriptors, capacity)
  local r = StartMenuRegistry.new({ canonicalIds = CANONICAL_IDS, capacity = capacity or 9 })
  for _, entry in ipairs(descriptors or {}) do
    r:register(entry)
  end
  return r
end

local function registry(descriptors, capacity)
  local r = newRegistry(descriptors, capacity)
  r:seal()
  return r
end

-- The fresh-game policy build the runtime feeds into compose (no capabilities
-- registered beyond start_menu itself).
local function policyEntries()
  return StartMenuPolicy.build({
    context = "normal_field",
    progression = { hasPokedex = false, hasStarter = false, bagUnlocked = false, hasPokegear = false },
    capabilities = { "start_menu" },
  })
end

local function modEntry(entries, id)
  for _, entry in ipairs(entries) do
    if entry.id == id then
      return entry
    end
  end
  return nil
end

function T.tests.registration_validates_the_full_descriptor()
  local r = newRegistry()
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ id = "" }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ label = "" }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ placement = {} }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ placement = { before = "a", after = "b" } }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ icon = 7 }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    r:register(fullDescriptor({ targetApplication = 7 }))
  end)
  throwsCode("START_MENU_REGISTRY_INVALID_DESCRIPTOR", function()
    local notATable = "not a table" ---@type any
    r:register(notATable)
  end)
end

function T.tests.duplicate_and_reserved_ids_are_rejected()
  local r = newRegistry()
  r:register(fullDescriptor())
  throwsCode("START_MENU_REGISTRY_DUPLICATE_ID", function()
    r:register(fullDescriptor())
  end)
  throwsCode("START_MENU_REGISTRY_RESERVED_ID", function()
    r:register(fullDescriptor({ id = "vanilla.trainer_card" }))
  end)
  throwsCode("START_MENU_REGISTRY_RESERVED_ID", function()
    r:register(fullDescriptor({ id = "vanilla.pokedex" }))
  end)
end

function T.tests.registration_after_sealing_is_rejected()
  local r = registry({ fullDescriptor() })
  throwsCode("START_MENU_REGISTRY_ALREADY_SEALED", function()
    r:register(fullDescriptor({ id = "my_mod.other" }))
  end)
end

function T.tests.unknown_anchors_are_rejected_at_seal()
  local r = newRegistry()
  r:register(fullDescriptor({ placement = { after = "my_mod.missing" } }))
  throwsCode("START_MENU_REGISTRY_UNKNOWN_ANCHOR", function()
    r:seal()
  end)
end

function T.tests.placement_cycles_are_rejected_with_both_action_names()
  local r = newRegistry()
  r:register(fullDescriptor({ id = "my_mod.a", placement = { after = "my_mod.b" } }))
  r:register(fullDescriptor({ id = "my_mod.b", placement = { after = "my_mod.a" } }))
  local err = Assert.throws(function()
    r:seal()
  end) ---@type any
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, "START_MENU_REGISTRY_PLACEMENT_CYCLE")
  Assert.isTrue(err.context.ids[1] == "my_mod.a" or err.context.ids[1] == "my_mod.b")
  Assert.isTrue(err.context.ids[2] == "my_mod.a" or err.context.ids[2] == "my_mod.b")
end

-- A self-anchored action is a one-action cycle: the diagnostic names it
-- instead of reporting a missing second action.
function T.tests.self_anchored_actions_are_rejected_as_cycles()
  local r = newRegistry()
  r:register(fullDescriptor({ id = "my_mod.self", placement = { after = "my_mod.self" } }))
  local err = Assert.throws(function()
    r:seal()
  end) ---@type any
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, "START_MENU_REGISTRY_PLACEMENT_CYCLE")
  Assert.equal(err.context.ids[1], "my_mod.self")
end

function T.tests.compose_without_mods_returns_the_policy_entries_untouched()
  local r = registry()
  local entries = policyEntries()
  local composed = r:compose(entries, { "start_menu" })
  Assert.equal(#composed, #entries)
  for index, entry in ipairs(entries) do
    Assert.equal(composed[index].id, entry.id)
    Assert.equal(composed[index].displayPosition, entry.displayPosition)
    Assert.equal(composed[index].enabled, entry.enabled)
  end
end

function T.tests.a_mod_after_trainer_card_sits_between_it_and_the_next_present_action()
  local r = registry({ fullDescriptor() })
  local composed = r:compose(policyEntries(), { "start_menu", "my_mod.quest_log" })
  local card = modEntry(composed, "vanilla.trainer_card") ---@type any
  local save = modEntry(composed, "vanilla.save") ---@type any
  local mod = modEntry(composed, "my_mod.quest_log") ---@type any
  Assert.notNil(mod, "the mod entry is merged into the composed list")
  Assert.equal(mod.present, true)
  Assert.equal(mod.vanillaEnabled, true)
  Assert.equal(mod.enabled, true, "a registered destination enables the mod action")
  Assert.equal(mod.normalVisible, true)
  Assert.equal(mod.developerVisible, true)
  Assert.equal(mod.message, "msg.my_mod.quest_log")
  Assert.equal(mod.displayPosition, card.displayPosition + 1)
  Assert.equal(mod.displayPosition, save.displayPosition - 1)
end

function T.tests.a_capability_missing_mod_target_is_a_disabled_action_not_a_failure()
  local r = registry({ fullDescriptor() })
  local composed = r:compose(policyEntries(), { "start_menu" })
  local mod = modEntry(composed, "my_mod.quest_log") ---@type any
  Assert.notNil(mod)
  Assert.equal(mod.capabilityAvailable, false)
  Assert.equal(mod.enabled, false)
  Assert.equal(mod.normalVisible, false)
  Assert.equal(mod.developerVisible, true, "developer mode still inspects the disabled action")
end

function T.tests.before_placement_inserts_in_front_of_the_anchor()
  local r = registry({ fullDescriptor({ placement = { before = "vanilla.save" } }) })
  local composed = r:compose(policyEntries(), { "start_menu", "my_mod.quest_log" })
  local entries = {}
  for _, entry in ipairs(composed) do
    if entry.present then
      entries[#entries + 1] = entry.id
    end
  end
  Assert.equal(entries[2], "my_mod.quest_log", "the mod lands directly before vanilla.save")
end

function T.tests.mod_anchors_may_reference_other_mods()
  local r = registry({
    fullDescriptor({ id = "my_mod.quest_log", placement = { after = "vanilla.trainer_card" } }),
    fullDescriptor({ id = "my_mod.quest_log_pro", placement = { after = "my_mod.quest_log" } }),
  })
  local composed = r:compose(policyEntries(), { "start_menu", "my_mod.quest_log", "my_mod.quest_log_pro" })
  local pro = modEntry(composed, "my_mod.quest_log_pro") ---@type any
  local log = modEntry(composed, "my_mod.quest_log") ---@type any
  Assert.equal(pro.displayPosition, log.displayPosition + 1)
end

-- A placement-less mod is legal (seal appends it after the canonical order)
-- and composes onto the end of the merged list, never crashing the merge.
function T.tests.a_placement_less_mod_lands_at_the_end_of_the_composed_order()
  local placementLess = fullDescriptor()
  placementLess.placement = nil
  local r = registry({
    placementLess,
    fullDescriptor({ id = "my_mod.b", placement = { after = "vanilla.trainer_card" } }),
  })
  local composed = r:compose(policyEntries(), { "start_menu", "my_mod.quest_log", "my_mod.b" })
  local mod = modEntry(composed, "my_mod.quest_log") ---@type any
  Assert.notNil(mod, "the placement-less mod is merged into the composed list")
  Assert.equal(mod.present, true)
  Assert.equal(mod.enabled, true, "the registered placement-less mod target enables it")
  Assert.equal(composed[#composed].id, mod.id, "the placement-less mod lands after the last canonical entry")
end

function T.tests.special_positions_remain_reserved_when_mods_are_present()
  local r = registry({ fullDescriptor() })
  local composed = r:compose(policyEntries(), { "start_menu", "my_mod.quest_log" })
  Assert.equal(modEntry(composed, "vanilla.special_9").displayPosition, 7)
  Assert.equal(modEntry(composed, "vanilla.special_10").displayPosition, 8)
end

function T.tests.capacity_exceeded_raises_the_structured_diagnostic_with_ids_and_count()
  local descriptors = {}
  for index = 1, 9 do
    descriptors[index] =
      fullDescriptor({ id = "my_mod.extra_" .. index, placement = { after = "vanilla.running_shoes" } })
  end
  local r = registry(descriptors)
  local err = Assert.throws(function()
    r:compose(policyEntries(), { "start_menu" })
  end) ---@type any
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, "START_MENU_CAPACITY_EXCEEDED")
  Assert.isTrue(err.context.count >= 10, "the diagnostic carries the visible count")
  Assert.isTrue(err.context.ids[1] ~= nil, "the diagnostic carries the visible action ids")
end

function T.tests.compose_before_seal_is_rejected()
  local r = newRegistry()
  throwsCode("START_MENU_REGISTRY_NOT_SEALED", function()
    r:compose(policyEntries(), {})
  end)
end

function T.tests.canonical_order_exposes_the_full_semantic_sequence()
  local order = StartMenuPolicy.canonicalOrder()
  Assert.equal(order[1], "vanilla.retire")
  Assert.equal(order[7], "vanilla.trainer_card")
  Assert.equal(order[10], "vanilla.running_shoes")
  Assert.equal(order[12], "vanilla.special_10")
  Assert.equal(#order, 12)
end

return T
