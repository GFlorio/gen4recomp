-- Signpost opcode runtime tests: the canonical signpost_direction and
-- signpost_set handlers execute the source behavior through the injected
-- signpost host — immediate show + instant print for 55, queued SHOW for 56,
-- both yielding exactly one scheduler tick, both requiring foreground
-- ownership, and neither writing world variables (opcode 55's unused out
-- operand is never written).

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local Scheduler = require("libs.engine.src.script.Scheduler")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

-- The script host surface the handlers exercise, conforming to the real
-- ScriptSignpostHost interface. Every method records its call; the scheduler
-- never sees a controller, so the fake is the injected boundary.
local RecordingSignpostHost = {}
RecordingSignpostHost.__index = RecordingSignpostHost

function RecordingSignpostHost.new()
  return setmetatable({
    appearances = {},
    commands = {},
    advances = 0,
    prints = {},
  }, RecordingSignpostHost)
end

function RecordingSignpostHost:setCommand(command)
  self.commands[#self.commands + 1] = command
end

function RecordingSignpostHost:setSourceAppearance(appearance)
  self.appearances[#self.appearances + 1] = appearance
end

function RecordingSignpostHost:printInstant(message, bindings, textArgs)
  self.prints[#self.prints + 1] = { message = message, bindings = bindings, textArgs = textArgs }
end

function RecordingSignpostHost:advance()
  self.advances = self.advances + 1
end

local function harness()
  local services = FakeServices.new()
  local signpost = RecordingSignpostHost.new()
  services.signpost = signpost
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = require("libs.engine.src.script.TaskRegistry").new(),
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    signpost = signpost,
    registry = registry,
    composition = composition,
    scheduler = scheduler,
  }
end

-- The canonical generated node shapes (opcode 55 and 56 lowering output).
local DIRECTION_NODE = {
  op = "signpost_direction",
  message = { message = "external", bank = 542, id = 34 },
  sourceAppearance = { game = "hgss", type = 0, map = 11 },
  sourceUnusedOut = "VAR_SPECIAL_RESULT",
}

local SET_NODE = {
  op = "signpost_set",
  sourceAppearance = { game = "hgss", type = 2, map = 0 },
}

-- 55: store appearance, select SHOW and execute it in-handler, print the
-- resolved message instantly, yield exactly one tick, and never touch the
-- unused out operand.
function T.direction_signpost_shows_prints_and_yields_exactly_once()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.signpost_direction",
    steps = {
      DIRECTION_NODE,
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.deepEqual(h.signpost.appearances, { { game = "hgss", type = 0, map = 11 } })
  Assert.deepEqual(h.signpost.commands, { "show" }, "55 selects SHOW")
  Assert.equal(h.signpost.advances, 1, "55 executes the command immediately")
  Assert.equal(#h.signpost.prints, 1, "55 prints its message instantly")
  Assert.deepEqual(h.signpost.prints[1].message, { message = "external", bank = 542, id = 34 })
  -- The unused out operand is never written: the sentinel stays.
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0)
  -- Exactly one tick later the script reaches its next node.
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "55 must yield its own tick")
  h.scheduler:step(101, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 56: store appearance and queue SHOW without executing it, print nothing,
-- yield exactly one tick.
function T.set_signpost_map_queues_show_without_executing_and_yields_once()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.signpost_set",
    steps = {
      SET_NODE,
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.deepEqual(h.signpost.appearances, { { game = "hgss", type = 2, map = 0 } })
  Assert.deepEqual(h.signpost.commands, { "show" }, "56 queues SHOW")
  Assert.equal(h.signpost.advances, 0, "56 does not execute the queued command")
  Assert.equal(#h.signpost.prints, 0, "56 prints nothing")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "56 must yield its own tick")
  h.scheduler:step(101, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- Both operations require foreground ownership: a background script that
-- reaches them faults with SCRIPT_BACKGROUND_FORBIDDEN and acquires nothing.
function T.signpost_operations_are_foreground_only()
  for _, node in ipairs({ DIRECTION_NODE, SET_NODE }) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.signpost_background",
      steps = { node, S.stop() },
    })
    h.registry:installBase(script.id, script, "generated")
    local composed = assert(h.composition:effective(script.id))
    local instanceId = h.scheduler:createBackground(composed, nil, 100)
    h.scheduler:step(100, nil)
    Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_BACKGROUND_FORBIDDEN")
    Assert.equal(#h.signpost.commands, 0, "the background script must acquire nothing")
    Assert.equal(h.signpost.advances, 0)
  end
end

-- A missing signpost service is an attributed fault, never a silent skip.
function T.signpost_operations_fault_without_the_host_service()
  local h = harness()
  h.services.signpost = nil
  local script = S.script({
    api = 1,
    id = "test.signpost_no_service",
    steps = { SET_NODE, S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_SERVICE_MISSING")
end

return { tests = T }
