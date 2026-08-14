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
local TrainerTipsTask = require("libs.engine.src.script.tasks.TrainerTipsTask")
local WaitSignpostTask = require("libs.engine.src.script.tasks.WaitSignpostTask")

local T = {}

-- The script host surface the handlers exercise, conforming to the real
-- ScriptSignpostHost interface. Every method records its call; the scheduler
-- never sees a controller, so the fake is the injected boundary. The current
-- command and print states are test fields the wait tests flip to model the
-- fixed-tick controller returning to nop / finishing its typed print.
local RecordingSignpostHost = {}
RecordingSignpostHost.__index = RecordingSignpostHost

function RecordingSignpostHost.new()
  return setmetatable({
    appearances = {},
    commands = {},
    advances = 0,
    prints = {},
    stops = 0,
    closes = 0,
    command = "nop",
    printDone = false,
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
  self.prints[#self.prints + 1] = { kind = "instant", message = message, bindings = bindings, textArgs = textArgs }
end

function RecordingSignpostHost:printTyped(message, bindings, textArgs)
  self.prints[#self.prints + 1] = { kind = "typed", message = message, bindings = bindings, textArgs = textArgs }
end

function RecordingSignpostHost:stopPrint()
  self.stops = self.stops + 1
end

function RecordingSignpostHost:close()
  self:stopPrint()
  self.closes = self.closes + 1
  self.command = "nop"
  self.printDone = false
end

function RecordingSignpostHost:advance()
  self.advances = self.advances + 1
end

function RecordingSignpostHost:status()
  return { command = self.command, printDone = self.printDone }
end

local function harness()
  local services = FakeServices.new()
  local signpost = RecordingSignpostHost.new()
  services.signpost = signpost
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = require("libs.engine.src.script.TaskRegistry").new()
  taskRegistry:register(WaitSignpostActionTask.type, WaitSignpostActionTask.version, WaitSignpostActionTask)
  taskRegistry:register(TrainerTipsTask.type, TrainerTipsTask.version, TrainerTipsTask)
  taskRegistry:register(WaitSignpostTask.type, WaitSignpostTask.version, WaitSignpostTask)
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

-- The canonical generated node shapes (opcodes 59/60 lowering output). The
-- result vars ride the task result through the scheduler reference path.
local TRAINER_TIPS_NODE = {
  op = "trainer_tips_print",
  message = { message = "external", bank = 542, id = 34 },
  result = { value = "var", id = "VAR_SPECIAL_RESULT" },
}

local WAIT_SIGNPOST_NODE = {
  op = "wait_signpost",
  result = { value = "var", id = "VAR_SPECIAL_RESULT" },
}

-- 59: the handler prints the resolved message through the host at the typed
-- cadence and blocks on the registered task; normal completion writes 2
-- through the scheduler result reference, and the script resumes on the
-- following tick.
function T.trainer_tips_print_starts_a_typed_print_and_completes_two_on_normal_completion()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.trainer_tips",
    steps = {
      TRAINER_TIPS_NODE,
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.equal(#h.signpost.prints, 1, "59 prints through the host")
  Assert.equal(h.signpost.prints[1].kind, "typed", "59 prints at the typed cadence, never instantly")
  Assert.deepEqual(h.signpost.prints[1].message, { message = "external", bank = 542, id = 34 })
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "59 must block on its task")
  local tasks = h.scheduler:tasks()
  Assert.equal(#tasks, 1)
  Assert.equal(tasks[1].taskType, "trainer_tips_print")

  -- The task polls printDone and never completes on fixed ticks while the
  -- print is live.
  h.scheduler:step(101, {})
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the wait must not finish on fixed ticks")
  Assert.equal(#h.scheduler:tasks(), 1)

  -- Normal completion: result 2 written through the scheduler result
  -- reference on the promotion tick; the script resumes one tick later.
  h.signpost.printDone = true
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "completion never resumes in the completion tick")
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, "the result is not written before promotion")
  h.scheduler:step(104, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 2, "normal completion writes 2")
end

-- A directional edge pressed while the typed print is still live stops the
-- printer, turns the player to that direction, closes the window, and
-- completes with 0 — for every one of the four directions. The player is
-- turned away from the pressed direction before each press so the facing
-- assertion can never pass vacuously.
function T.trainer_tips_directional_interrupt_stops_turns_and_writes_zero_for_every_direction()
  local opposite = { north = "south", south = "north", west = "east", east = "west" }
  for _, direction in ipairs({ "north", "south", "west", "east" }) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.trainer_tips",
      steps = {
        TRAINER_TIPS_NODE,
        S.setVar({ variable = "VAR_AFTER", value = 1 }),
        S.stop(),
      },
    })
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})

    h.services.player:turn(opposite[direction])
    h.scheduler:step(101, { pressedDirection = direction })
    Assert.equal(h.services.player:facing(), direction, direction .. " interrupt must turn the player")
    Assert.equal(h.signpost.stops, 1, direction .. " interrupt must stop the printer")
    Assert.equal(h.signpost.closes, 1, direction .. " interrupt must close the window")
    h.scheduler:step(102, {})
    Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, direction .. " interrupt writes 0")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
    Assert.equal(#h.scheduler:tasks(), 0, direction .. " interrupt must complete the task")
  end
end

-- A/B during the print is the printer's speed-up behavior, never a
-- dismissal: the edges must not complete the task, and the print still
-- completes normally with 2. The print path also reads no pointer edge (the
-- input snapshot has none), so the signpost print never speeds up on touch.
function T.trainer_tips_ignores_ab_edges_during_the_print()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.trainer_tips",
    steps = {
      TRAINER_TIPS_NODE,
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})

  h.scheduler:step(101, { pressedAction = true })
  Assert.equal(#h.scheduler:tasks(), 1, "A during the print must not dismiss the signpost")
  h.scheduler:step(102, { pressedCancel = true })
  Assert.equal(#h.scheduler:tasks(), 1, "B during the print must not dismiss the signpost")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)

  h.signpost.printDone = true
  h.scheduler:step(103, {})
  h.scheduler:step(104, {})
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 2, "A/B during the print must not change the result")
end

-- 60: the handler always blocks on the registered task (no same-tick path);
-- A and B dismiss with result 0 and close the window without turning the
-- player.
function T.wait_signpost_always_blocks_and_ab_dismiss_with_zero()
  for _, edge in ipairs({ "pressedAction", "pressedCancel" }) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.wait_signpost",
      steps = {
        WAIT_SIGNPOST_NODE,
        S.setVar({ variable = "VAR_AFTER", value = 1 }),
        S.stop(),
      },
    })
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

    h.scheduler:step(100, {})
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "60 must always block")
    local tasks = h.scheduler:tasks()
    Assert.equal(#tasks, 1)
    Assert.equal(tasks[1].taskType, "wait_signpost")

    local input = {}
    input[edge] = true
    local before = h.services.player:facing()
    h.scheduler:step(101, input)
    Assert.equal(h.signpost.closes, 1, edge .. " must close the window")
    Assert.equal(h.services.player:facing(), before, edge .. " must not turn the player")
    h.scheduler:step(102, {})
    Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, edge .. " dismissal writes 0")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  end
end

-- A directional edge dismisses like A/B but additionally turns the player to
-- the pressed direction — for every one of the four directions.
function T.wait_signpost_directional_dismissal_turns_the_player_for_every_direction()
  local opposite = { north = "south", south = "north", west = "east", east = "west" }
  for _, direction in ipairs({ "north", "south", "west", "east" }) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.wait_signpost",
      steps = {
        WAIT_SIGNPOST_NODE,
        S.setVar({ variable = "VAR_AFTER", value = 1 }),
        S.stop(),
      },
    })
    h.registry:installBase(script.id, script, "generated")
    h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
    h.scheduler:step(100, {})

    h.services.player:turn(opposite[direction])
    h.scheduler:step(101, { pressedDirection = direction })
    Assert.equal(h.services.player:facing(), direction, direction .. " dismissal must turn the player")
    Assert.equal(h.signpost.closes, 1, direction .. " dismissal must close the window")
    h.scheduler:step(102, {})
    Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, direction .. " dismissal writes 0")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  end
end

-- Both operations are foreground-only and require the signpost host: a
-- background script faults with SCRIPT_BACKGROUND_FORBIDDEN and a missing
-- service with SCRIPT_SERVICE_MISSING, each acquiring nothing.
function T.trainer_tips_and_wait_signpost_are_foreground_only_and_require_the_host()
  for _, node in ipairs({ TRAINER_TIPS_NODE, WAIT_SIGNPOST_NODE }) do
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
    Assert.equal(#h.scheduler:tasks(), 0, "the background script must acquire nothing")
    Assert.equal(#h.signpost.prints, 0)
  end

  local missing = harness()
  missing.services.signpost = nil
  local scriptNoService = S.script({
    api = 1,
    id = "test.wait_signpost_no_service",
    steps = { WAIT_SIGNPOST_NODE, S.stop() },
  })
  missing.registry:installBase(scriptNoService.id, scriptNoService, "generated")
  local missingInstance =
    missing.scheduler:createForeground(assert(missing.composition:effective(scriptNoService.id)), nil, 100)
  missing.scheduler:step(100, {})
  Assert.equal(assert(missing.services.events:eventFor("script.error", missingInstance)).code, "SCRIPT_SERVICE_MISSING")
  Assert.equal(#missing.scheduler:tasks(), 0)
end

-- Cancelling an instance while its signpost task owns the presented window
-- releases it exactly once through the host close (stop the printer, hide
-- the window, return the command to nop): the script fault-cleanup contract,
-- for both task types.
function T.trainer_tips_and_wait_signpost_cancel_closes_the_signpost_exactly_once()
  for _, node in ipairs({ TRAINER_TIPS_NODE, WAIT_SIGNPOST_NODE }) do
    local h = harness()
    local script = S.script({
      api = 1,
      id = "test.signpost_cancel",
      steps = { node, S.stop() },
    })
    h.registry:installBase(script.id, script, "generated")
    local composed = assert(h.composition:effective(script.id))
    local instanceId = h.scheduler:createForeground(composed, nil, 100)
    h.scheduler:step(100, {})
    Assert.equal(#h.scheduler:tasks(), 1)
    Assert.equal(h.signpost.closes, 0)

    h.scheduler:cancelInstance(instanceId, "test cancellation")
    Assert.equal(h.signpost.closes, 1, "the signpost task must close the window exactly once on cancel")
    Assert.equal(h.signpost.stops, 1, node.op .. " cancel must stop the printer")
    Assert.equal(#h.scheduler:tasks(), 0)
  end
end

-- The registered task state is strictly validated: non-table or markerless
-- state is an unserializable task record, never a silent acceptance.
function T.trainer_tips_and_wait_signpost_states_validate_strictly()
  for _, impl in ipairs({ TrainerTipsTask, WaitSignpostTask }) do
    local markerless = {} ---@type any
    local nonTable = 7 ---@type any
    local err = impl.validate(markerless)
    ---@cast err Errors.Error
    Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
    local err2 = impl.validate(nonTable)
    ---@cast err2 Errors.Error
    Assert.equal(err2.code, "SCRIPT_TASK_UNSERIALIZABLE")
    Assert.isNil(impl.validate({ waiting = true }))
  end
end

return { tests = T }
