-- Pure FieldSignpostController tests: the signpost command state machine
-- (SHOW/HIDE finish on their own update; WIPE_IN/WIPE_OUT make exactly three
-- 16px motion updates with the command held at the endpoint and complete on
-- the following endpoint-check update), the presentation snapshot, and
-- the window printer (instant completion, injected fixed-cadence typed
-- reveal, stoppable without a live printer). No render-frame timing.

local Assert = require("tests.support.Assert")
local FieldSignpostController = require("libs.engine.src.FieldSignpostController")

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
    ticksPerGlyph = opts.ticksPerGlyph,
    styleId = opts.styleId,
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
    logicalYOffset = -32,
    sourceAppearance = { game = "hgss", type = 0, map = 42 },
    styleId = "hgss.signpost",
    visibleLines = {},
    printDone = false,
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
  Assert.deepEqual(pattern, { 0, 1, 1, 2, 2, 3, 3 })
  Assert.equal(c:status().printDone, false, "the third glyph is not the last")
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 4)
  Assert.equal(c:status().printDone, true, "printDone lands with the last glyph")
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 4, "the finished printer stays put")
end

-- The reveal cadence is injected at construction (the runtime wires
-- FieldPlayerData.ticksPerGlyph); the controller has no fixed speed of its
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
  Assert.equal(revealedGlyphs(fast:status()), 1, "cadence 2 reveals at tick 2")
  Assert.equal(revealedGlyphs(slow:status()), 0, "cadence 3 has not revealed by tick 2")
  slow:updateFixed()
  Assert.equal(revealedGlyphs(slow:status()), 1, "cadence 3 reveals at tick 3")
end

-- A typed print can be stopped without leaving a live printer: the revealed
-- text freezes, printDone stays false, and later updates never advance it.
function T.stopped_print_freezes_without_a_live_printer()
  local lines = { line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }
  local c = controller(lines)
  c:printTyped(message(lines))
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 1)
  c:stopPrint()
  c:updateFixed()
  c:updateFixed()
  c:updateFixed()
  Assert.equal(revealedGlyphs(c:status()), 1, "the frozen text never advances again")
  Assert.equal(c:status().printDone, false, "a stopped print is not done")
end

function T.stopping_without_a_live_printer_is_a_noop()
  local c = controller({})
  c:stopPrint()
  c:printInstant(message({ line({ glyph("A", 1) }) }))
  c:stopPrint()
  Assert.equal(c:status().printDone, true, "an already-finished print is not affected")
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

return { tests = T }
