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
local SignTask = require("libs.engine.src.script.tasks.SignTask")

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
    fills = 0,
    closes = 0,
    styles = {},
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

function RecordingSignpostHost:setStyleId(styleId)
  self.styleId = styleId
  self.styles[#self.styles + 1] = styleId
end

function RecordingSignpostHost:printInstant(message, bindings, textArgs)
  self.prints[#self.prints + 1] = { kind = "instant", message = message, bindings = bindings, textArgs = textArgs }
end

function RecordingSignpostHost:printTyped(message, bindings, textArgs)
  self.prints[#self.prints + 1] = { kind = "typed", message = message, bindings = bindings, textArgs = textArgs }
end

function RecordingSignpostHost:finishPrint()
  self.fills = self.fills + 1
  self.printDone = true
end

-- The host's explicit cleanup: the presented window and printer are cleared
-- and the command returns to idle on the call.
function RecordingSignpostHost:close()
  self.closes = self.closes + 1
  self.command = "nop"
  self.printDone = false
end

function RecordingSignpostHost:advance()
  self.advances = self.advances + 1
end

function RecordingSignpostHost:isCommandIdle()
  return self.command == "nop"
end

function RecordingSignpostHost:status()
  return { command = self.command, printDone = self.printDone }
end

local function harness()
  local services = FakeServices.new()
  local signpost = RecordingSignpostHost.new()
  services.signpost = signpost
  -- The sealed window-style registry surface the high-level sign handlers
  -- resolve appearances against: the three built-ins plus a registered mod
  -- style.
  local styles = { "hgss.signpost", "hgss.trainer_tip", "mod.route_sign" }
  services.windowStyles = {
    resolve = function(_, id)
      for _, known in ipairs(styles) do
        if known == id then
          return {}
        end
      end
      return nil
    end,
  }
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = require("libs.engine.src.script.TaskRegistry").new()
  taskRegistry:register(WaitSignpostActionTask.type, WaitSignpostActionTask.version, WaitSignpostActionTask)
  taskRegistry:register(TrainerTipsTask.type, TrainerTipsTask.version, TrainerTipsTask)
  taskRegistry:register(WaitSignpostTask.type, WaitSignpostTask.version, WaitSignpostTask)
  taskRegistry:register(SignTask.type, SignTask.version, SignTask)
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

-- A directional edge pressed while the typed print is still live interrupts
-- the print (the host cleanup clears the window and printer), turns the
-- player to that direction, and completes with 0 — for every one of the
-- four directions. The player is turned away from the pressed direction
-- before each press so the facing assertion can never pass vacuously.
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
    Assert.equal(h.signpost.closes, 1, direction .. " interrupt must close the window")
    h.scheduler:step(102, {})
    Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, direction .. " interrupt writes 0")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
    Assert.equal(#h.scheduler:tasks(), 0, direction .. " interrupt must complete the task")
  end
end

-- A/B during the live print is the instant-fill operation, never a
-- dismissal: the whole message reveals on the input tick through
-- host:finishPrint, the window is never closed, and the task completes with
-- the normal print-complete result 2. The print path also reads no pointer
-- edge (the input snapshot has none), so the signpost print never fills on
-- touch.
function T.trainer_tips_ab_during_the_live_print_fills_and_completes_two()
  for _, edge in ipairs({ "pressedAction", "pressedCancel" }) do
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

    local input = {}
    input[edge] = true
    h.scheduler:step(101, input)
    Assert.equal(h.signpost.fills, 1, edge .. " during the print must fill the whole message")
    Assert.isTrue(h.signpost.printDone, edge .. " must complete the print on the input tick")
    Assert.equal(h.signpost.closes, 0, edge .. " must not dismiss the signpost")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the task completes in the input tick")

    h.scheduler:step(102, {})
    Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 2, edge .. " during the print writes the result 2")
    Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
    Assert.equal(#h.scheduler:tasks(), 0, edge .. " during the print must complete the task")
  end
end

-- Direction and A on the same live-print tick: the direction wins — the
-- print is interrupted rather than filled, the player turns, the window
-- closes, and the task completes 0.
function T.trainer_tips_direction_and_action_on_the_same_tick_prefers_the_direction()
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

  h.services.player:turn("south")
  h.scheduler:step(101, { pressedDirection = "west", pressedAction = true })
  Assert.equal(h.services.player:facing(), "west", "the direction wins the same-tick edge")
  Assert.equal(h.signpost.closes, 1, "the direction interrupts the signpost")
  Assert.equal(h.signpost.fills, 0, "the same-tick A must not fill the print")
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 0, "the direction writes its interrupt result 0")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- An edge on the tick the print is already complete is after the fact: the
-- completion branch wins (result 2) and the fill operation never runs.
function T.trainer_tips_already_complete_with_a_completes_two_without_filling()
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

  h.signpost.printDone = true
  h.scheduler:step(101, { pressedAction = true })
  Assert.equal(h.signpost.fills, 0, "the completion branch wins before the fill branch")
  Assert.equal(h.signpost.closes, 0)
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_RESULT"), 2, "the completed print still writes 2")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
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
-- releases it exactly once through the host close (the explicit cleanup
-- clears the printer, hides the window, and returns the command to idle):
-- the script fault-cleanup contract, for both task types.
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
    Assert.equal(#h.scheduler:tasks(), 0)
  end
end

-- Cancelling an instance blocked in wait_signpost_action releases the
-- signpost through the task's own cancel: the wait task owns the presented
-- window it blocks on, and its cancel callback closes the host exactly once.
function T.wait_signpost_action_cancel_closes_the_signpost_exactly_once()
  local h = harness()
  h.signpost.command = "wipe_in"
  local script = S.script({
    api = 1,
    id = "test.wait_signpost_action_cancel",
    steps = { { op = "wait_signpost_action" }, S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  local composed = assert(h.composition:effective(script.id))
  local instanceId = h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(#h.scheduler:tasks(), 1)
  Assert.equal(h.signpost.closes, 0)

  h.scheduler:cancelInstance(instanceId, "test cancellation")
  Assert.equal(h.signpost.closes, 1, "the wait task must close the window exactly once on cancel")
  Assert.equal(#h.scheduler:tasks(), 0)
end

-- The wait task's own cancel marks its state with the reason and closes the
-- signpost only when the service is reachable; a context without one (the
-- scheduler tears down environments with the task record) never faults.
function T.wait_signpost_action_cancel_marks_state_and_is_safe_without_a_service()
  local state = {}
  WaitSignpostActionTask.cancel(state, "reason", nil)
  Assert.equal(state.cancelled, "reason")
  local noService = {}
  WaitSignpostActionTask.cancel(noService, "reason", { services = {} })
  Assert.equal(noService.cancelled, "reason")
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

-- The compiled-graph path of the generated common.signpost resource: a
-- copy_var step carries both its var-ref `source` operand and provenance.
-- The compiler must keep the operand on the node (the provenance payload
-- rides only on provenance-less nodes), so the runtime handler copies the
-- actual variable instead of faulting EVENT_VAR_ID_INVALID over a
-- provenance table.
function T.compiled_copy_var_with_provenance_copies_the_operand_source()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.copy_var_provenance",
    metadata = { generated = true, source = { member = 3, scriptIndex = 0 } },
    steps = {
      {
        op = "copy_var",
        destination = { id = "VAR_SPECIAL_x8008", value = "var" },
        source = { id = "VAR_SPECIAL_RESULT", value = "var" },
        provenance = { offsets = { 1176 }, opcodes = { 42 } },
      },
      S.stop(),
    },
  })
  h.services.world:setVar("VAR_SPECIAL_RESULT", 5)
  h.registry:installBase(script.id, script, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(h.services.world:getVar("VAR_SPECIAL_x8008"), 5)
  Assert.isNil(h.services.events:eventFor("script.error", instanceId), "the copy must not fault")
  Assert.equal(#h.scheduler:tasks(), 0)
end

-- ScrCmd_061: no operands, ends the script context and requests the Start
-- Menu reopen hook. The request must reach the startMenuReopen service
-- exactly once and the run must stop (the compiled graph has no next edge);
-- a missing service is an attributed fault, never a silent success.
function T.request_start_menu_requests_the_hook_once_and_stops_the_script()
  local requests = 0
  local h = harness()
  h.services.startMenuReopen = {
    request = function()
      requests = requests + 1
    end,
  }
  local script = S.script({
    api = 1,
    id = "test.request_start_menu",
    steps = {
      { op = "request_start_menu" },
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(requests, 1, "the startMenuReopen hook must be requested exactly once")
  h.scheduler:step(101, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the script context must end at the request node")
  Assert.equal(#h.scheduler:tasks(), 0)
end

function T.request_start_menu_requires_the_reopen_service()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.request_start_menu_no_service",
    steps = { { op = "request_start_menu" } },
  })
  h.registry:installBase(script.id, script, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_SERVICE_MISSING")
end

-- The high-level sign operations: S.sign presents the window with the
-- requested style (never source type/map data) and prints instantly; with
-- wait=true the registered sign task blocks until an A/B/directional
-- dismissal closes the window, and the script resumes on the following
-- tick. No result reference rides along.
local SIGN_NODE = {
  op = "sign",
  message = "msg.hgss.0542.00034",
  appearance = "mod.route_sign",
  wait = true,
}

local TRAINER_TIP_NODE = {
  op = "trainer_tip",
  message = "msg.hgss.0542.00036",
  appearance = "trainer_tip",
}

function T.high_level_sign_presents_with_the_style_prints_instantly_and_waits_for_dismissal()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign",
    steps = { SIGN_NODE, S.setVar({ variable = "VAR_AFTER", value = 1 }), S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.deepEqual(h.signpost.styles, { "mod.route_sign" }, "S.sign routes the requested style id")
  Assert.deepEqual(h.signpost.commands, { "show" }, "S.sign selects SHOW")
  Assert.equal(h.signpost.advances, 1, "S.sign executes the show immediately")
  Assert.equal(#h.signpost.prints, 1, "S.sign prints its message instantly")
  Assert.equal(h.signpost.prints[1].kind, "instant")
  Assert.equal(#h.signpost.appearances, 0, "S.sign must never carry source type/map data")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "wait=true must block on the sign task")
  local tasks = h.scheduler:tasks()
  Assert.equal(#tasks, 1)
  Assert.equal(tasks[1].taskType, "sign")

  -- The instant print is complete, so the A edge is a dismissal, not a
  -- speed-up: close exactly once and resume on the following tick.
  h.signpost.printDone = true
  h.scheduler:step(101, { pressedAction = true })
  Assert.equal(h.signpost.closes, 1, "A must dismiss the high-level signpost")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "completion never resumes in the completion tick")
  h.scheduler:step(102, {})
  Assert.equal(#h.scheduler:tasks(), 0)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- A directional edge dismisses the high-level sign and turns the player,
-- exactly like the imported WaitSignpost path.
function T.high_level_sign_directional_dismissal_turns_the_player()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign",
    steps = { SIGN_NODE, S.setVar({ variable = "VAR_AFTER", value = 1 }), S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})

  h.services.player:turn("south")
  h.scheduler:step(101, { pressedDirection = "west" })
  Assert.equal(h.services.player:facing(), "west", "the dismissal must turn the player")
  Assert.equal(h.signpost.closes, 1)
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- wait=false opens the window and continues in the same tick: no sign task
-- is created and the next node runs in the start tick.
function T.high_level_sign_with_wait_false_continues_in_the_same_tick()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign",
    steps = {
      { op = "sign", message = "msg.hgss.0542.00034", appearance = "sign", wait = false },
      S.setVar({ variable = "VAR_AFTER", value = 1 }),
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.deepEqual(h.signpost.styles, { "hgss.signpost" }, "the semantic appearance resolves to the built-in")
  Assert.equal(h.signpost.advances, 1, "the window must be presented in-handler")
  Assert.equal(#h.scheduler:tasks(), 0, "wait=false must not create a sign task")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1, "wait=false must continue in the same tick")
end

-- S.trainerTip types at the player cadence and blocks; a directional edge
-- during the live print is the source interruption (stop, turn, close), an
-- A/B edge is the printer's speed-up (never a dismissal), and after the
-- print completes an A/B edge dismisses.
function T.high_level_trainer_tip_types_then_waits_for_dismissal()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.trainer_tip",
    steps = { TRAINER_TIP_NODE, S.setVar({ variable = "VAR_AFTER", value = 1 }), S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)

  h.scheduler:step(100, {})
  Assert.deepEqual(h.signpost.styles, { "hgss.trainer_tip" }, "S.trainerTip routes the semantic style")
  Assert.equal(#h.signpost.prints, 1, "S.trainerTip starts its print in-handler")
  Assert.equal(h.signpost.prints[1].kind, "typed", "S.trainerTip types at the player cadence, never instantly")
  Assert.equal(#h.signpost.appearances, 0, "S.trainerTip must never carry source type/map data")
  local tasks = h.scheduler:tasks()
  Assert.equal(#tasks, 1)
  Assert.equal(tasks[1].taskType, "sign")

  -- A/B during the live print is the printer's speed-up: the whole message
  -- fills immediately, the window stays presented, and the task keeps
  -- waiting for the dismissal edge.
  h.scheduler:step(101, { pressedAction = true })
  Assert.equal(#h.scheduler:tasks(), 1, "A during the print must not dismiss the trainer tip")
  Assert.equal(h.signpost.fills, 1, "A during the live print must fill the remaining message")
  Assert.equal(h.signpost.closes, 0)

  -- A directional edge after the fill is still the source interruption.
  h.services.player:turn("south")
  h.scheduler:step(102, { pressedDirection = "east" })
  Assert.equal(h.services.player:facing(), "east", "the interrupt must turn the player")
  Assert.equal(h.signpost.closes, 1, "the interrupt must close the window")
  h.scheduler:step(103, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

function T.high_level_trainer_tip_dismisses_after_the_print_completes()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.trainer_tip",
    steps = { TRAINER_TIP_NODE, S.setVar({ variable = "VAR_AFTER", value = 1 }), S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})

  h.signpost.printDone = true
  h.scheduler:step(101, { pressedAction = true })
  Assert.equal(h.signpost.closes, 1, "A after the print completes must dismiss the trainer tip")
  h.scheduler:step(102, {})
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- An appearance naming an unregistered style is an attributed script fault
-- (SCRIPT_STYLE_UNKNOWN), and the handler acquires nothing before it.
function T.high_level_sign_faults_on_an_unregistered_style()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign_unknown_style",
    steps = {
      { op = "sign", message = "msg.hgss.0542.00034", appearance = "mod.missing" },
      S.stop(),
    },
  })
  h.registry:installBase(script.id, script, "generated")
  local instanceId = h.scheduler:createForeground(assert(h.composition:effective(script.id)), nil, 100)
  h.scheduler:step(100, {})
  local err = assert(h.services.events:eventFor("script.error", instanceId))
  Assert.equal(err.code, "SCRIPT_STYLE_UNKNOWN")
  Assert.equal(err.context.styleId, "mod.missing")
  Assert.equal(#h.signpost.styles, 0, "the fault must acquire nothing")
  Assert.equal(#h.signpost.commands, 0)
  Assert.equal(#h.signpost.prints, 0)
  Assert.equal(#h.scheduler:tasks(), 0)
end

-- The high-level operations are foreground-only and require both the
-- signpost host and the window-style registry service.
function T.high_level_sign_operations_require_foreground_and_services()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign_background",
    steps = { SIGN_NODE, S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  local composed = assert(h.composition:effective(script.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.services.events:eventFor("script.error", instanceId)).code, "SCRIPT_BACKGROUND_FORBIDDEN")
  Assert.equal(#h.signpost.styles, 0, "the background script must acquire nothing")

  local missingStyles = harness()
  missingStyles.services.windowStyles = nil
  local noStyles = S.script({
    api = 1,
    id = "test.sign_no_styles",
    steps = { SIGN_NODE, S.stop() },
  })
  missingStyles.registry:installBase(noStyles.id, noStyles, "generated")
  local noStylesInstance =
    missingStyles.scheduler:createForeground(assert(missingStyles.composition:effective(noStyles.id)), nil, 100)
  missingStyles.scheduler:step(100, {})
  Assert.equal(
    assert(missingStyles.services.events:eventFor("script.error", noStylesInstance)).code,
    "SCRIPT_SERVICE_MISSING"
  )

  local missingSignpost = harness()
  missingSignpost.services.signpost = nil
  local noSignpost = S.script({
    api = 1,
    id = "test.sign_no_signpost",
    steps = { SIGN_NODE, S.stop() },
  })
  missingSignpost.registry:installBase(noSignpost.id, noSignpost, "generated")
  local noSignpostInstance =
    missingSignpost.scheduler:createForeground(assert(missingSignpost.composition:effective(noSignpost.id)), nil, 100)
  missingSignpost.scheduler:step(100, {})
  Assert.equal(
    assert(missingSignpost.services.events:eventFor("script.error", noSignpostInstance)).code,
    "SCRIPT_SERVICE_MISSING"
  )
end

-- Cancelling an instance while its sign task owns the presented window
-- releases it exactly once through the host close.
function T.high_level_sign_cancel_closes_the_signpost_exactly_once()
  local h = harness()
  local script = S.script({
    api = 1,
    id = "test.sign_cancel",
    steps = { SIGN_NODE, S.stop() },
  })
  h.registry:installBase(script.id, script, "generated")
  local composed = assert(h.composition:effective(script.id))
  local instanceId = h.scheduler:createForeground(composed, nil, 100)
  h.scheduler:step(100, {})
  Assert.equal(#h.scheduler:tasks(), 1)
  Assert.equal(h.signpost.closes, 0)

  h.scheduler:cancelInstance(instanceId, "test cancellation")
  Assert.equal(h.signpost.closes, 1, "the sign task must close the window exactly once on cancel")
  Assert.equal(#h.scheduler:tasks(), 0)
end

-- The registered sign task state is strictly validated: non-table or
-- markerless state is an unserializable task record, never a silent
-- acceptance.
function T.high_level_sign_state_validates_strictly()
  local markerless = {} ---@type any
  local nonTable = 7 ---@type any
  local err = SignTask.validate(markerless)
  ---@cast err Errors.Error
  Assert.equal(err.code, "SCRIPT_TASK_UNSERIALIZABLE")
  local err2 = SignTask.validate(nonTable)
  ---@cast err2 Errors.Error
  Assert.equal(err2.code, "SCRIPT_TASK_UNSERIALIZABLE")
  Assert.isNil(SignTask.validate({ waiting = true }))
end

return { tests = T }
