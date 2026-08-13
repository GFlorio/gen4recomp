-- FieldEventState tests freeze the numeric flag/variable store: unsigned 16-bit
-- keys, clear/zero defaults, idempotent writes that notify nobody, and a save
-- round trip that keeps keys numeric. Pure; no LÖVE and no imported data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.engine.src.FieldEventState")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

function T.absent_flags_are_clear_and_absent_vars_are_zero()
  local state = FieldEventState.new()
  Assert.isFalse(state:isFlagSet(401))
  Assert.equal(state:getVar(0x4000), 0)
end

function T.set_and_clear_round_trip()
  local state = FieldEventState.new()
  state:setFlag(401)
  Assert.isTrue(state:isFlagSet(401))
  state:clearFlag(401)
  Assert.isFalse(state:isFlagSet(401))
end

function T.flag_zero_is_an_ordinary_key()
  local state = FieldEventState.new()
  Assert.isFalse(state:isFlagSet(0))
  state:setFlag(0)
  Assert.isTrue(state:isFlagSet(0))
end

function T.subscribers_receive_old_new_and_tick()
  local state = FieldEventState.new()
  local seen = {}
  state:subscribe(function(change)
    seen[#seen + 1] = change
  end)
  state:setTick(42)
  state:setFlag(401)
  state:setVar(3, 7)
  Assert.equal(#seen, 2)
  Assert.deepEqual(seen[1], { kind = "flag", id = 401, oldValue = false, newValue = true, tick = 42 })
  Assert.deepEqual(seen[2], { kind = "var", id = 3, oldValue = 0, newValue = 7, tick = 42 })
end

function T.idempotent_writes_do_not_notify()
  local state = FieldEventState.new({ flags = { [401] = true } })
  local count = 0
  state:subscribe(function()
    count = count + 1
  end)
  state:setFlag(401)
  state:clearFlag(9)
  state:setVar(3, 0)
  Assert.equal(count, 0)
end

function T.unsubscribe_stops_notifications()
  local state = FieldEventState.new()
  local count = 0
  local unsubscribe = state:subscribe(function()
    count = count + 1
  end)
  state:setFlag(1)
  unsubscribe()
  state:setFlag(2)
  Assert.equal(count, 1)
end

function T.self_unsubscribe_does_not_skip_the_next_listener()
  local state = FieldEventState.new()
  local order = {}
  local unsubscribe
  unsubscribe = state:subscribe(function()
    order[#order + 1] = "first"
    unsubscribe()
  end)
  state:subscribe(function()
    order[#order + 1] = "second"
  end)
  state:setFlag(401)
  Assert.deepEqual(order, { "first", "second" })
end

function T.unsubscribing_mid_notification_applies_to_later_notifications()
  local state = FieldEventState.new()
  local firstCount, secondCount = 0, 0
  local unsubscribe
  unsubscribe = state:subscribe(function()
    firstCount = firstCount + 1
    unsubscribe()
  end)
  state:subscribe(function()
    secondCount = secondCount + 1
  end)
  state:setFlag(401)
  state:setFlag(402)
  Assert.equal(firstCount, 1)
  Assert.equal(secondCount, 2)
end

function T.subscribers_added_during_a_notification_do_not_receive_it()
  local state = FieldEventState.new()
  local lateCount = 0
  state:subscribe(function()
    state:subscribe(function()
      lateCount = lateCount + 1
    end)
  end)
  state:setFlag(401)
  Assert.equal(lateCount, 0)
  state:setFlag(402)
  Assert.equal(lateCount, 1)
end

function T.serialize_round_trip_keeps_numeric_keys()
  local state = FieldEventState.new()
  state:setFlag(401)
  state:setVar(0x4001, 65535)
  local serialized = state:serialize()
  Assert.equal(serialized.flags[401], true)
  Assert.equal(serialized.vars[0x4001], 65535)

  local restored = FieldEventState.new(serialized)
  Assert.isTrue(restored:isFlagSet(401))
  Assert.equal(restored:getVar(0x4001), 65535)
  -- A serialized snapshot is a copy: later writes must not reach it.
  state:setFlag(7)
  Assert.isNil(serialized.flags[7])
end

function T.invalid_flag_ids_are_rejected()
  local state = FieldEventState.new()
  throwsCode("EVENT_FLAG_ID_INVALID", function()
    state:setFlag(-1)
  end)
  throwsCode("EVENT_FLAG_ID_INVALID", function()
    state:setFlag(0x10000)
  end)
  throwsCode("EVENT_FLAG_ID_INVALID", function()
    state:isFlagSet(1.5)
  end)
end

function T.invalid_variable_ids_and_values_are_rejected()
  local state = FieldEventState.new()
  throwsCode("EVENT_VAR_ID_INVALID", function()
    state:setVar(0x10000, 1)
  end)
  throwsCode("EVENT_VAR_VALUE_INVALID", function()
    state:setVar(3, -1)
  end)
  throwsCode("EVENT_VAR_VALUE_INVALID", function()
    state:setVar(3, 0x10000)
  end)
end

function T.stored_flag_values_use_a_value_specific_error()
  throwsCode("EVENT_FLAG_VALUE_INVALID", function()
    FieldEventState.new({ flags = { [401] = "yes" } })
  end)
  throwsCode("EVENT_FLAG_VALUE_INVALID", function()
    FieldEventState.new({ flags = { [401] = false } })
  end)
end

function T.invalid_ticks_are_rejected()
  local state = FieldEventState.new()
  local bad = { -1, 0.5, 0 / 0, math.huge, -math.huge }
  for i = 1, #bad do
    Assert.throws(function()
      state:setTick(bad[i])
    end)
  end
end

function T.valid_ticks_are_accepted_and_stamped_on_changes()
  local state = FieldEventState.new()
  local seen = {}
  state:subscribe(function(change)
    seen[#seen + 1] = change.tick
  end)
  state:setTick(0)
  state:setFlag(401)
  state:setTick(123456)
  state:setVar(3, 7)
  Assert.deepEqual(seen, { 0, 123456 })
end

function T.serialized_input_is_validated()
  throwsCode("EVENT_FLAG_ID_INVALID", function()
    FieldEventState.new({ flags = { ["401"] = true } })
  end)
  throwsCode("EVENT_VAR_VALUE_INVALID", function()
    FieldEventState.new({ vars = { [3] = 70000 } })
  end)
end

function T.oversized_stores_are_rejected()
  local flags = {}
  for id = 0, FieldEventState.MAX_ENTRIES do
    flags[id] = true
  end
  throwsCode("EVENT_STATE_TOO_LARGE", function()
    FieldEventState.new({ flags = flags })
  end)
end

return { tests = T }
