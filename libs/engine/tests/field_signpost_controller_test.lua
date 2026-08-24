-- Pure FieldSignpostController tests: the signpost command state machine
-- (SHOW/HIDE finish on their own update; WIPE_IN/WIPE_OUT make exactly three
-- 16px motion updates with the command held at the endpoint and complete on
-- the following endpoint-check update), the presentation snapshot, and
-- the window printer (instant completion, injected fixed-cadence typed
-- reveal, instant fill). No render-frame timing.

local Assert = require("tests.support.Assert")
local FieldSignpostController = require("libs.engine.src.FieldSignpostController")
local TextSpeedPolicy = require("libs.engine.src.TextSpeedPolicy")

local T = {}

local function glyph(text, code)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function line(tokens)
  return { tokens = tokens, width = 0 }
end

-- Formatted message carrying the layout lines the test layout returns.
local function message(lines)
  local tokens = {}
  for _, ln in ipairs(lines) do
    for _, token in ipairs(ln.tokens) do
      tokens[#tokens + 1] = token
    end
  end
  return { bankId = 543, messageId = 5, tokens = tokens, _lines = lines }
end

-- Controller whose layout returns the message's precomputed lines verbatim.
---@param lines { tokens: MessageToken[] }[]
---@param opts { ticksPerGlyph: integer?, styleId: string? }?
---@return FieldSignpostController
local function controller(lines, opts)
  opts = opts or {}
  return FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    policy = {
      interGlyphDelay = (opts.ticksPerGlyph or 2) - 1,
      glyphBudget = 1,
      abAcceleration = false,
    },
    styleId = opts.styleId,
  })
end

local function acceleratedController()
  return FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    policy = TextSpeedPolicy.forSpeed("mid"),
  })
end

local function revealedGlyphs(status)
  local count = 0
  for _, ln in ipairs(status.visibleLines) do
    for _, token in ipairs(ln) do
      if token.kind == "glyph" then
        count = count + 1
      end
    end
  end
  return count
end

function T.fresh_controller_is_hidden_with_the_default_presentation()
  local c = controller({})
  local status = c:status()
  Assert.equal(status.active, false)
  Assert.equal(status.command, "nop")
  Assert.equal(status.logicalYOffset, -48, "the hidden signpost BG starts at -48")
  Assert.equal(status.previousLogicalYOffset, -48, "the interpolation history starts coherent with the offset")
  Assert.isNil(status.sourceAppearance)
  Assert.equal(status.styleId, "hgss.signpost", "the default style id is hgss.signpost")
  Assert.deepEqual(status.visibleLines, {})
  Assert.equal(status.printDone, false)
  Assert.isFalse(c:isModal())
end

function T.style_id_is_injected_presentation_data()
  local c = controller({}, { styleId = "my_mod.sign" })
  Assert.equal(c:status().styleId, "my_mod.sign")
end

-- The high-level sign path routes a script-requested style id into the
-- controller: setStyleId replaces the presentation style without touching
-- any other state.
function T.set_style_id_routes_the_requested_style()
  local c = controller({}, { styleId = "hgss.signpost" })
  c:setStyleId("mod.route_sign")
  Assert.equal(c:status().styleId, "mod.route_sign")
  Assert.equal(c:status().active, false, "style routing must not touch presentation state")
  c:setStyleId("hgss.trainer_tip")
  Assert.equal(c:status().styleId, "hgss.trainer_tip")
end

-- The routed style ends with the presentation it styled: the hide case and
-- the wipe-out endpoint check return it to the construction default, so a
-- high-level flow never leaks its style into a later flow.
function T.presentation_end_restores_the_routed_style()
  local c = controller({}, { styleId = "hgss.signpost" })
  c:setStyleId("mod.route_sign")
  c:setCommand("hide")
  c:updateFixed()
  Assert.equal(c:status().styleId, "hgss.signpost", "hide must restore the default style")

  c:setStyleId("mod.route_sign")
  c:setCommand("wipe_out")
  for _ = 1, 3 do
    c:updateFixed()
    Assert.equal(c:status().styleId, "mod.route_sign", "motion updates keep the routed style")
  end
  c:updateFixed()
  Assert.equal(c:status().styleId, "hgss.signpost", "the wipe-out endpoint check must restore the default style")
end

-- The style id is routing data: malformed values are programming faults.
function T.set_style_id_rejects_malformed_ids()
  local c = controller({})
  local empty = "" ---@type any
  local number = 7 ---@type any
  Assert.throws(function()
    c:setStyleId(empty)
  end)
  Assert.throws(function()
    c:setStyleId(number)
  end)
end

-- Dispose releases the routed style back to the initial default exactly
-- once with the rest of the hidden state.
function T.dispose_resets_the_routed_style_to_the_default()
  local c = controller({}, { styleId = "hgss.signpost" })
  c:setStyleId("mod.route_sign")
  c:dispose()
  Assert.equal(c:status().styleId, "hgss.signpost", "dispose must restore the default style id")
end

-- The presentation snapshot is presentation-ready: exact field set of plain
-- data (no LÖVE objects), and fresh copies so a consumer cannot mutate the
-- controller through its status.
function T.status_exposes_the_presentation_snapshot()
  local c = controller({})
  c:setSourceAppearance({ game = "hgss", type = 0, map = 42 })
  c:setCommand("show")
  c:updateFixed()
  c:setCommand("wipe_in")
  c:updateFixed()
  local status = c:status()
  Assert.deepEqual(status, {
    active = true,
    command = "wipe_in",
    previousLogicalYOffset = -48,
    logicalYOffset = -32,
    sourceAppearance = { game = "hgss", type = 0, map = 42 },
    styleId = "hgss.signpost",
    visibleLines = {},
    printDone = false,
    revealedGlyphs = 0,
    totalGlyphs = 0,
  })
  status.sourceAppearance.type = 99
  Assert.equal(c:status().sourceAppearance.type, 0, "mutating the snapshot cannot leak into the controller")
end

-- SHOW completes on its own audited source update (the source case clears
-- the command within the case): the window becomes presented on the BG at
-- its initial -48 position and the command returns to nop. Show invents no
-- text.
function T.show_finishes_on_its_own_update_and_invents_no_text()
  local c = controller({})
  c:setCommand("show")
  Assert.equal(c:status().command, "show", "the assignment is visible before the update")
  c:updateFixed()
  local status = c:status()
  Assert.equal(status.command, "nop", "SHOW clears the command on its own update")
  Assert.equal(status.active, true)
  Assert.equal(status.logicalYOffset, -48, "the window is created on the BG at its initial position")
  Assert.isTrue(c:isModal())
  Assert.deepEqual(status.visibleLines, {}, "show does not invent text")
  Assert.equal(status.printDone, false)
end

-- HIDE completes on its own audited source update and clears the active
-- presentation (window and any printed text), resetting the stored BG offset
-- to 0 like the source case.
function T.hide_finishes_on_its_own_update_and_clears_presentation()
  local c = controller({ line({ glyph("A", 1) }) })
  c:setCommand("show")
  c:updateFixed()
  c:printInstant(message({ line({ glyph("A", 1) }) }))
  Assert.equal(c:status().printDone, true)
  c:setCommand("hide")
  c:updateFixed()
  local status = c:status()
  Assert.equal(status.command, "nop", "HIDE clears the command on its own update")
  Assert.equal(status.active, false)
  Assert.isFalse(c:isModal())
  Assert.equal(status.logicalYOffset, 0, "HIDE resets the stored BG offset to 0")
  Assert.deepEqual(status.visibleLines, {}, "hide clears the active presentation")
  Assert.equal(status.printDone, false)
end

-- WIPE_IN moves +16px per field update from the hidden -48 position; the
-- command is held on the update that reaches the endpoint and only the
-- following endpoint-check update returns it to nop.
function T.wipe_in_makes_three_motion_updates_and_completes_on_the_endpoint_check()
  local c = controller({})
  c:setCommand("show")
  c:updateFixed()
  c:setCommand("wipe_in")
  local offsets = {}
  for _ = 1, 3 do
    c:updateFixed()
    offsets[#offsets + 1] = c:status().logicalYOffset
    Assert.equal(c:status().command, "wipe_in", "the command is held during the motion updates")
  end
  Assert.deepEqual(offsets, { -32, -16, 0 })
  Assert.equal(c:status().active, true, "the window stays presented while sliding in")
  c:updateFixed()
  Assert.equal(c:status().logicalYOffset, 0)
  Assert.equal(c:status().command, "nop", "the endpoint-check update returns the command to nop")
end

-- WIPE_OUT moves -16px per field update; the update that observes -48
-- clears the tile area, resets the stored BG offset to 0, and returns the
-- command to nop. The snapshot on that tick presents a cleared window: the
-- cleared window must not flash at the reset position.
function T.wipe_out_clears_and_resets_on_the_endpoint_check_without_flash()
  local lines = { line({ glyph("A", 1) }) }
  local c = controller(lines)
  c:setCommand("show")
  c:updateFixed()
  c:setCommand("wipe_in")
  for _ = 1, 4 do
    c:updateFixed()
  end
  Assert.equal(c:status().logicalYOffset, 0, "the wipe-in reaches the presented position")
  c:printInstant(message(lines))
  Assert.equal(c:status().printDone, true)
  c:setCommand("wipe_out")
  local offsets = {}
  for _ = 1, 3 do
    c:updateFixed()
    offsets[#offsets + 1] = c:status().logicalYOffset
    Assert.equal(c:status().command, "wipe_out", "the command is held during the motion updates")
  end
  Assert.deepEqual(offsets, { -16, -32, -48 })
  Assert.equal(c:status().active, true, "the window stays presented while sliding out")
  c:updateFixed()
  local status = c:status()
  Assert.equal(status.logicalYOffset, 0, "the stored BG offset resets to 0")
  Assert.equal(status.command, "nop")
  Assert.equal(status.active, false, "the cleared window must not flash at the reset position")
  Assert.deepEqual(status.visibleLines, {}, "the tile area is cleared with the text")
  Assert.equal(status.printDone, false)
end

-- Signpost_SetCommand is a bare assignment with no busy guard: replacing a
-- running command never rejects, and the next update acts on the new
-- command. Only updateFixed moves the command back to nop.
function T.set_command_replaces_a_running_command_without_rejection()
  local c = controller({})
  c:setCommand("show")
  c:updateFixed()
  c:setCommand("wipe_in")
  c:updateFixed()
  Assert.equal(c:status().logicalYOffset, -32)
  c:setCommand("wipe_out")
  Assert.equal(c:status().command, "wipe_out", "replacement is accepted mid-wipe")
  c:updateFixed()
  Assert.equal(c:status().logicalYOffset, -48, "the new command takes effect on the next update")
  Assert.equal(c:status().command, "wipe_out")
  c:updateFixed()
  Assert.equal(c:status().command, "nop")
  Assert.equal(c:status().active, false)
end

function T.rejects_an_unknown_command()
  local c = controller({})
  local err = Assert.throws(function()
    local unknown = "explode" ---@type any
    c:setCommand(unknown)
  end)
  Assert.isTrue(
    type(err) == "string" and err:find("unknown signpost command", 1, true) ~= nil,
    "unknown command must raise a programming-fault assertion"
  )
end

-- The source appearance (type/map) is presentation data: validated at set
-- time, copied, and never resolved into geometry.
function T.source_appearance_is_validated_and_copied()
  local c = controller({})
  local appearance = { game = "hgss", type = 0, map = 42 }
  c:setSourceAppearance(appearance)
  appearance.map = 99
  Assert.deepEqual(
    c:status().sourceAppearance,
    { game = "hgss", type = 0, map = 42 },
    "the stored copy is captured at set time"
  )
  c:setSourceAppearance(nil)
  Assert.isNil(c:status().sourceAppearance, "nil clears the appearance")
end

function T.rejects_a_malformed_source_appearance()
  local c = controller({})
  local bad = {
    { game = "sapphire", type = 0, map = 0 },
    { game = "hgss", type = -1, map = 0 },
    { game = "hgss", type = 0, map = 0.5 },
    "hgss",
  }
  for _, appearance in ipairs(bad) do
    Assert.throws(function()
      c:setSourceAppearance(appearance)
    end, "malformed source appearance must be rejected")
  end
end

function T.instant_print_completes_immediately()
  local lines = { line({ glyph("A", 1) }), line({ glyph("B", 2) }) }
  local c = controller(lines)
  c:printInstant(message(lines))
  local status = c:status()
  Assert.equal(status.printDone, true)
  Assert.equal(#status.visibleLines, 2, "both lines are visible at once")
  Assert.equal(status.visibleLines[1][1], lines[1].tokens[1])
  Assert.equal(status.visibleLines[2][1], lines[2].tokens[1])
  c:updateFixed()
  Assert.equal(c:status().printDone, true, "no printer is left advancing")
  Assert.equal(revealedGlyphs(c:status()), 2)
end

-- Typed print reveals glyphs at the injected fixed-tick cadence (2 ticks per
-- glyph by default). Progress is deterministic per update and printDone
-- lands exactly when the last glyph reveals.
function T.typed_print_reveals_at_the_injected_fixed_tick_cadence()
  local lines = {
    line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }),
    line({ glyph("D", 4) }),
  }
  local c = controller(lines)
  c:printTyped(message(lines))
  local pattern = {}
  for _ = 1, 7 do
    c:updateFixed()
    pattern[#pattern + 1] = revealedGlyphs(c:status())
  end
  Assert.deepEqual(pattern, { 1, 2, 3, 4, 4, 4, 4 })
  Assert.equal(c:status().printDone, true, "the final reveal completes the print")
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 4)
  Assert.equal(c:status().printDone, true, "printDone lands with the last glyph")
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 4, "the finished printer stays put")
end

-- The reveal cadence is injected at construction (the runtime wires
-- PlayerData.ticksPerGlyph); the controller has no fixed speed of its
-- own.
function T.injected_ticks_per_glyph_drives_the_reveal_cadence()
  local lines = { line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }
  local slow = controller(lines, { ticksPerGlyph = 3 })
  local fast = controller(lines, { ticksPerGlyph = 2 })
  slow:printTyped(message(lines))
  fast:printTyped(message(lines))
  for _ = 1, 2 do
    slow:updateFixed()
    fast:updateFixed()
  end
  Assert.equal(revealedGlyphs(fast:status()), 2, "cadence 2 reveals two glyphs by tick 2")
  Assert.equal(revealedGlyphs(slow:status()), 2, "the shared printer uses two substeps per update")
  slow:updateFixed()
  Assert.equal(revealedGlyphs(slow:status()), 2, "cadence 3 reveals the second glyph on the next update")
end

function T.signpost_edges_are_consumed_once_and_held_input_remains_visible()
  for _, edge in ipairs({ "pressedAction", "pressedCancel" }) do
    local lines = { line({ glyph("A", 1), glyph("B", 2), glyph("C", 3), glyph("D", 4) }) }
    local c = acceleratedController()
    c:printTyped(message(lines))

    local firstInput = { actionDown = false, cancelDown = false }
    firstInput[edge] = true
    c:updateFixed(firstInput)
    Assert.equal(revealedGlyphs(c:status()), 1, edge .. " reveals the due first glyph")

    c:updateFixed({})
    Assert.equal(revealedGlyphs(c:status()), 1, edge .. " must not be replayed by the second source substep")

    local heldInput = { actionDown = edge == "pressedAction", cancelDown = edge == "pressedCancel" }
    c:updateFixed(heldInput)
    Assert.equal(revealedGlyphs(c:status()), 2, edge .. " held state must remain visible without replaying a new edge")
  end
end

function T.signpost_new_edges_arm_acceleration_for_later_held_updates()
  local lines = { line({ glyph("A", 1), glyph("B", 2), glyph("C", 3), glyph("D", 4) }) }
  local c = acceleratedController()
  c:printTyped(message(lines))
  c:updateFixed()
  c:updateFixed({ pressedAction = true })
  c:updateFixed({ actionDown = true })
  Assert.equal(revealedGlyphs(c:status()), 3, "a legitimate new edge enables held acceleration")
end

-- A new print replaces the previous text only through the explicit print
-- request path; layout is captured when the new print begins.
function T.a_new_print_replaces_text_only_through_the_print_request()
  local first = { line({ glyph("A", 1) }) }
  local second = { line({ glyph("B", 2), glyph("C", 3) }) }
  local c = controller(second)
  c:printTyped(message(first))
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 1)
  c:printTyped(message(second))
  Assert.equal(revealedGlyphs(c:status()), 0, "the new print starts from a fresh reveal")
  c:updateFixed()
  c:updateFixed()
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 2)
  Assert.equal(c:status().printDone, true)
end

-- A failing injected layout rejects the print request: the layout's own
-- error propagates and the previous print and command state stay untouched.
function T.layout_failure_rejects_the_print_and_preserves_prior_state()
  local lines = { line({ glyph("A", 1) }) }
  local failLayout = false
  local failing = FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      if failLayout then
        error("layout exploded", 0)
      end
      return { lines = msg._lines }
    end,
    policy = TextSpeedPolicy.forSpeed("mid"),
  })
  failing:printInstant(message(lines))
  failing:setCommand("wipe_in")
  failLayout = true
  local err = Assert.throws(function()
    failing:printTyped(message(lines))
  end)
  Assert.equal(err, "layout exploded", "the layout error propagates")
  Assert.equal(failing:status().command, "wipe_in", "the command state is untouched by a failed print")
  Assert.equal(failing:status().printDone, true, "the prior instant print survives")
end

function T.rejects_a_print_request_without_a_token_stream()
  local c = controller({})
  local noTokens = { bankId = 1 } ---@type any
  Assert.throws(function()
    c:printInstant(noTokens)
  end, "print requires a token stream")
  local notAMessage = "hello" ---@type any
  Assert.throws(function()
    c:printTyped(notAMessage)
  end, "print requires a token stream")
end

-- Dispose releases every owned surface back to the initial hidden state and
-- is idempotent (session teardown path).
function T.dispose_resets_to_the_initial_hidden_state_and_is_idempotent()
  local c = controller({ line({ glyph("A", 1) }) })
  c:setSourceAppearance({ game = "hgss", type = 1, map = 4 })
  c:setCommand("show")
  c:updateFixed()
  c:printTyped(message({ line({ glyph("A", 1) }) }))
  c:setCommand("wipe_in")
  c:dispose()
  local status = c:status()
  Assert.equal(status.active, false)
  Assert.equal(status.command, "nop")
  Assert.equal(status.logicalYOffset, -48)
  Assert.isNil(status.sourceAppearance)
  Assert.deepEqual(status.visibleLines, {})
  Assert.equal(status.printDone, false)
  Assert.isFalse(c:isModal())
  c:dispose()
  Assert.equal(c:status().command, "nop", "a second dispose is a no-op")
end

-- The instant-fill operation: a live typed printer reveals the whole message
-- on the call, stops advancing, and leaves every other presentation field
-- untouched. Idempotent, and a no-op without a print.
function T.finish_print_fills_a_live_typed_print_and_touches_nothing_else()
  local lines = {
    line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }),
    line({ glyph("D", 4) }),
  }
  local c = controller(lines)
  c:setSourceAppearance({ game = "hgss", type = 0, map = 42 })
  c:setCommand("show")
  c:updateFixed()
  c:printTyped(message(lines))
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 2, "the print must be partway when the fill lands")
  local before = c:status()
  c:finishPrint()
  local status = c:status()
  Assert.isTrue(status.printDone, "finishPrint must complete the print")
  Assert.equal(revealedGlyphs(status), 4, "finishPrint must reveal the whole message")
  Assert.equal(status.active, before.active, "finishPrint must not alter active")
  Assert.equal(status.command, before.command, "finishPrint must not alter the command")
  Assert.equal(status.logicalYOffset, before.logicalYOffset, "finishPrint must not alter the offset")
  Assert.equal(
    status.previousLogicalYOffset,
    before.previousLogicalYOffset,
    "finishPrint must not alter the history pair"
  )
  Assert.equal(status.styleId, before.styleId, "finishPrint must not alter the style")
  Assert.deepEqual(status.sourceAppearance, before.sourceAppearance, "finishPrint must not alter the source appearance")
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 4, "the filled printer never advances again")
  Assert.isTrue(c:status().printDone)
end

function T.finish_print_without_a_live_print_is_a_noop_and_idempotent()
  local c = controller({ line({ glyph("A", 1) }) })
  local fresh = c:status()
  c:finishPrint()
  Assert.deepEqual(c:status(), fresh, "finishPrint without a print changes nothing")
  c:printInstant(message({ line({ glyph("A", 1) }) }))
  c:finishPrint()
  Assert.isTrue(c:status().printDone, "finishPrint on a finished print stays finished")
  c:printTyped(message({ line({ glyph("A", 1) }) }))
  c:finishPrint()
  c:finishPrint()
  Assert.isTrue(c:status().printDone, "a second finishPrint is a no-op")
  Assert.equal(revealedGlyphs(c:status()), 1)
end

-- The semantic print query is the controller's own: true exactly when the
-- active printer has revealed every glyph, false without a print, during a
-- typed reveal, and after the presentation ends.
function T.is_print_done_is_the_semantic_print_query()
  local lines = { line({ glyph("A", 1), glyph("B", 2) }) }
  local c = controller(lines, { ticksPerGlyph = 2 })
  Assert.isFalse(c:isPrintDone(), "no print means no completed print")
  c:printInstant(message(lines))
  Assert.isTrue(c:isPrintDone(), "an instant print is complete immediately")
  c:printTyped(message(lines))
  Assert.isFalse(c:isPrintDone(), "a typed print is not complete at reveal start")
  c:updateFixed()
  Assert.isFalse(c:isPrintDone(), "the first update does not finish both glyphs")
  c:updateFixed()
  Assert.isTrue(c:isPrintDone(), "the final reveal completes the print")
  c:setCommand("hide")
  c:updateFixed()
  Assert.isFalse(c:isPrintDone(), "the presentation end clears the printer")
end

-- The explicit cleanup operation: the window, printer, command, offset, and
-- routed style return to the completed-hide presentation on the call (no
-- updateFixed needed), the history pair rests coherently at the rest offset,
-- and the source appearance survives. Idempotent.
function T.hide_immediately_clears_the_presentation_and_is_idempotent()
  local lines = { line({ glyph("A", 1) }) }
  local c = controller(lines)
  c:setSourceAppearance({ game = "hgss", type = 0, map = 42 })
  c:setStyleId("mod.route_sign")
  c:setCommand("show")
  c:updateFixed()
  c:printInstant(message(lines))
  c:setCommand("wipe_in")
  c:updateFixed()
  Assert.isTrue(c:isModal())
  c:hideImmediately()
  local status = c:status()
  Assert.equal(status.active, false, "hideImmediately closes the window")
  Assert.equal(status.command, "nop", "hideImmediately returns the command to idle")
  Assert.equal(status.logicalYOffset, 0, "hideImmediately resets the stored BG offset")
  Assert.equal(status.previousLogicalYOffset, 0, "hideImmediately rests the history pair coherently")
  Assert.equal(status.styleId, "hgss.signpost", "hideImmediately restores the default style")
  Assert.deepEqual(status.visibleLines, {}, "hideImmediately clears the printer")
  Assert.equal(status.printDone, false)
  Assert.deepEqual(
    status.sourceAppearance,
    { game = "hgss", type = 0, map = 42 },
    "hideImmediately keeps the source appearance"
  )
  Assert.isFalse(c:isModal())
  c:hideImmediately()
  Assert.equal(c:status().command, "nop", "a second hideImmediately is a no-op")
  Assert.equal(c:status().logicalYOffset, 0)
end

-- The semantic command-idle query: true exactly when no command is scheduled;
-- the "nop" spelling is the controller's own protocol.
function T.is_command_idle_is_the_semantic_idle_query()
  local c = controller({})
  Assert.isTrue(c:isCommandIdle(), "a fresh controller is idle")
  c:setCommand("show")
  Assert.isFalse(c:isCommandIdle(), "a scheduled command is not idle")
  c:updateFixed()
  Assert.isTrue(c:isCommandIdle(), "a completed show returns to idle")
  c:setCommand("wipe_in")
  c:updateFixed()
  Assert.isFalse(c:isCommandIdle(), "a running wipe is not idle")
  for _ = 1, 3 do
    c:updateFixed()
  end
  Assert.isTrue(c:isCommandIdle(), "the wipe endpoint check returns to idle")
end

-- The wipe interpolation history: each updateFixed captures the offset at its
-- start, so every status read pairs with the previous read's current offset,
-- and the wipe-in endpoint rests the pair at (0, 0).
function T.wipe_history_pairs_every_update_and_rests_coherently()
  local c = controller({})
  local status = c:status()
  Assert.equal(status.previousLogicalYOffset, status.logicalYOffset, "the pair starts coherent")
  Assert.equal(status.previousLogicalYOffset, -48)
  c:setCommand("show")
  c:updateFixed()
  status = c:status()
  Assert.equal(status.previousLogicalYOffset, -48, "the show update captures the hidden offset")
  Assert.equal(status.logicalYOffset, -48)
  c:setCommand("wipe_in")
  local prior = status.logicalYOffset
  for _, offset in ipairs({ -32, -16, 0 }) do
    c:updateFixed()
    status = c:status()
    Assert.equal(status.previousLogicalYOffset, prior, "each read pairs with the previous read's current")
    Assert.equal(status.logicalYOffset, offset, "the wipe moves one 16px step per update")
    prior = status.logicalYOffset
  end
  c:updateFixed()
  status = c:status()
  Assert.equal(status.command, "nop")
  Assert.equal(status.previousLogicalYOffset, 0, "the wipe-in endpoint restarts the pair at the rest offset")
  Assert.equal(status.logicalYOffset, 0)
end

-- Every reset path rests both history fields together instead of leaving a
-- stale previous offset behind: the hide update, the wipe-out endpoint check,
-- the explicit cleanup, and dispose.
function T.every_reset_path_rests_the_history_pair_together()
  local function shown(c)
    c:setCommand("show")
    c:updateFixed()
    c:setCommand("wipe_in")
    for _ = 1, 4 do
      c:updateFixed()
    end
  end
  local c = controller({})
  shown(c)
  c:setCommand("hide")
  c:updateFixed()
  Assert.equal(c:status().previousLogicalYOffset, 0, "the hide update rests the previous offset")
  Assert.equal(c:status().logicalYOffset, 0, "the hide update rests the current offset")

  local c2 = controller({})
  shown(c2)
  c2:setCommand("wipe_out")
  for _ = 1, 4 do
    c2:updateFixed()
  end
  Assert.equal(c2:status().previousLogicalYOffset, 0, "the wipe-out endpoint check rests the previous offset")
  Assert.equal(c2:status().logicalYOffset, 0, "the wipe-out endpoint check rests the current offset")

  local c3 = controller({})
  shown(c3)
  c3:hideImmediately()
  Assert.equal(c3:status().previousLogicalYOffset, 0, "hideImmediately rests the previous offset")
  Assert.equal(c3:status().logicalYOffset, 0, "hideImmediately rests the current offset")

  local c4 = controller({})
  c4:setCommand("show")
  c4:updateFixed()
  c4:dispose()
  Assert.equal(c4:status().previousLogicalYOffset, -48, "dispose returns the pair to the initial hidden state")
  Assert.equal(c4:status().logicalYOffset, -48)
end

-- A typed print of an empty message is instantly complete and leaves no live
-- printer behind, so a fill or a later update stays harmless.
function T.typed_print_of_an_empty_message_is_instantly_complete_and_harmless()
  local c = controller({})
  c:printTyped(message({}))
  local status = c:status()
  Assert.isTrue(status.printDone, "an empty typed print is complete immediately")
  Assert.deepEqual(status.visibleLines, {})
  c:updateFixed()
  c:updateFixed()
  Assert.isTrue(c:status().printDone, "the completed empty print never advances")
  c:finishPrint()
  Assert.isTrue(c:status().printDone, "a fill on the empty print stays harmless")
end

return { tests = T }
