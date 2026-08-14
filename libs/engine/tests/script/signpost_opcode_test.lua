-- Signpost opcode runtime tests: the canonical signpost_direction,
-- signpost_set, signpost_command, and wait_signpost_action handlers execute
-- the source behavior through the injected signpost host — immediate show +
-- instant print for 55, queued SHOW for 56, command assignment without
-- in-handler execution for 57, same-tick continuation for 58 when the
-- command is already nop and a registered host-polling task when busy; the
-- yield/handlers require foreground ownership, and none write world
-- variables (opcode 55's unused out operand is never written; 58 has no
-- result reference).

local Assert = require("tests.support.Assert")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local Scheduler = require("libs.engine.src.script.Scheduler")
local FakeServices = require("tests.support.script.FakeServices")
local WaitSignpostActionTask = require("libs.engine.src.script.tasks.WaitSignpostActionTask")

local T = {}

-- The script host surface the handlers exercise, conforming to the real
-- ScriptSignpostHost interface. Every method records its call; the scheduler
-- never sees a controller, so the fake is the injected boundary. The current
-- command state is a test field the wait tests flip to model the fixed-tick
-- controller returning to nop.
local RecordingSignpostHost = {}
RecordingSignpostHost.__index = RecordingSignpostHost

function RecordingSignpostHost.new()
  return setmetatable({
    appearances = {},
    commands = {},
    advances = 0,
    prints = {},
    command = "nop",
  }, RecordingSignpostHost)
end

function RecordingSignpostHost:setCommand(command)
  self.command = command
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

function RecordingSignpostHost:status()
  return { command = self.command }
end

local function harness()
  local services = FakeServices.new()
  local signpost = RecordingSignpostHost.new()
  services.signpost = signpost
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = require("libs.engine.src.script.TaskRegistry").new()
  taskRegistry:register(WaitSignpostActionTask.type, WaitSignpostActionTask.version, WaitSignpostActionTask)
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
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

-- 57 with every semantic command value: the command is assigned to the
-- controller (setCommand only) with no in-handler advance, and the script
-- yields exactly one tick.
function T.signpost_command_forwards_every_semantic_command_without_executing()
  local commands = { "nop", "show", "wipe_out", "wipe_in", "hide" }
  for _, command in ipairs(commands) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.signpost_command",
      steps = {
        { op = "signpost_command", command = command },
        S.setVar({ variable = "VAR_AFTER", value = 1 }),
        S.stop(),
      },
    })
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

    h.scheduler:step(100, {})
    Assert.deepEqual(h.signpost.commands, { command }, command .. " is assigned to the controller")
    Assert.equal(h.signpost.advances, 0, command .. " must not execute in-handler")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, command .. " must yield its own tick")
    h.scheduler:step(101, {})
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  end
end

-- 58 with the command already nop continues in the same tick: the next node
-- executes in the start tick and no task is created.
function T.wait_signpost_action_continues_same_tick_when_command_is_nop()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.wait_signpost_action_nop",
    steps = {
      { op = "wait_signpost_action" },
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.equal(
    h.services.world:getVar("VAR_AFTER"),
    1,
    "58 must continue in its own tick when the command is already nop"
  )
  Assert.equal(#h.scheduler:tasks(), 0, "the same-tick path must not create a task")
end

-- 58 while the command is busy creates the registered task, which polls the
-- host's command and completes only when it returns to nop — never on a
-- fixed tick count — and carries no result reference (58 has no result
-- operand, so nothing is written on continuation).
function T.wait_signpost_action_blocks_while_busy_until_the_command_returns_to_nop()
  local h = harness()
  h.signpost.command = "wipe_in"
  local script = S.script({
    api = 1,
    id = "test.wait_signpost_action_busy",
    steps = {
      { op = "wait_signpost_action" },
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "58 must block while the command is busy")
  local tasks = h.scheduler:tasks()
  Assert.equal(#tasks, 1, "58 must create one registered task")
  Assert.equal(tasks[1].taskType, "wait_signpost_action")

  -- Not complete on a fixed tick count while the command stays busy.
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the wait must not finish on fixed ticks")
  Assert.equal(#h.scheduler:tasks(), 1)

  -- Completes only once the controller returns to nop; the script resumes
  -- on the following scheduler tick.
  h.signpost.command = "nop"
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "completion never resumes in the completion tick")
  h.scheduler:step(104, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  -- The only world writes are the script's own setVar: the task carries no
  -- result reference.
  local writes = {}
  for _, call in ipairs(h.services.world.calls) do
    if call.op == "setVar" then
      writes[#writes + 1] = call.id
    end
  end
  Assert.deepEqual(writes, { "VAR_AFTER" })
end

-- The wait operation also requires foreground ownership and the host
-- service: background scripts fault with SCRIPT_BACKGROUND_FORBIDDEN and
-- missing services with SCRIPT_SERVICE_MISSING, each acquiring nothing.
function T.wait_signpost_action_is_foreground_only_and_requires_the_host()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.wait_signpost_action_background",
    steps = { { op = "wait_signpost_action" }, S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  local composed = assert(h.composition:effective(script.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_BACKGROUND_FORBIDDEN")
  Assert.equal(#h.scheduler:tasks(), 0, "the background script must acquire nothing")

  local missing = harness()
  missing.services.signpost = nil
  local scriptNoService = S.script({
    api = 1,
    id = "test.wait_signpost_action_no_service",
    steps = { { op = "wait_signpost_action" }, S.stop() },
  })
  missing.registry:installBase(scriptNoService.id, scriptNoService, "generated")
  local missingInstance =
    missing.scheduler:createForeground(assert(missing.composition:effective(scriptNoService.id)), nil, 100)
  missing.scheduler:step(100, {})
  Assert.equal(assert(missing.services.events:eventFor("script.error", missingInstance)).code, "SCRIPT_SERVICE_MISSING")
  Assert.equal(#missing.scheduler:tasks(), 0)
end

return { tests = T }
