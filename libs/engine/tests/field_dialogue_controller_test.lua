-- Headless dialogue controller tests:
-- fixed-tick typewriter reveal, Action reveal/advance/close semantics, cancel
-- policy, auto-scroll pages, exactly-once completion, error unwind, and the
-- deterministic cursor blink. Layout and input are injected, so the whole
-- lifecycle runs without LÖVE.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")

local T = {}

local function glyph(text, code)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function page(lines, breakKind)
  return { lines = lines, breakKind = breakKind }
end

local function line(tokens)
  return { tokens = tokens, width = 0 }
end

-- Controller whose layout returns the caller's precomputed pages verbatim.
local function controller(pages, opts)
  opts = opts or {}
  return FieldDialogueController.new({
    layout = function()
      return { pages = pages, warnings = opts.warnings or {} }
    end,
    ticksPerGlyph = opts.ticksPerGlyph or 2,
    cursorBlinkTicks = opts.cursorBlinkTicks or 30,
  })
end

local function message(pages)
  return {
    bankId = 543,
    messageId = 5,
    tokens = { glyph("A", 0x0121), glyph("B", 0x0122) },
    _pages = pages,
  }
end

local function request(id, message, allowCancel)
  return {
    id = id,
    message = message,
    style = "default",
    modal = true,
    allowCancel = allowCancel == true,
  }
end

function T.fixed_ticks_reveal_expected_glyph_count()
  local c = controller({ page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }) }, "eos") })
  c:open(request("t", message()))
  Assert.equal(c:status().state, "OPENING")
  c:step({})
  Assert.equal(c:status().state, "REVEALING")
  Assert.equal(c:status().revealedGlyphs, 0)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 1)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 1, "one glyph per two ticks")
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 2)
  c:step({})
  Assert.equal(c:status().revealedGlyphs, 3)
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.action_during_reveal_jumps_to_boundary_only()
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2), glyph("C", 3), glyph("D", 4), glyph("E", 5) }) }, "prompt"),
    page({ line({ glyph("F", 6) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  c:step({ actionPressed = true })
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  Assert.equal(c:status().revealedGlyphs, 5)
  -- The revealing Action is consumed: a held button without a new edge does
  -- not advance the boundary.
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  Assert.equal(c:status().pageIndex, 1)
  c:step({ actionPressed = true })
  Assert.equal(c:status().pageIndex, 2)
  Assert.equal(c:status().state, "REVEALING")
  Assert.equal(c:status().revealedGlyphs, 0)
end

function T.held_action_does_not_skip_multiple_pages()
  local c = controller({
    page({ line({ glyph("A", 1) }) }, "prompt"),
    page({ line({ glyph("B", 2), glyph("C", 3), glyph("D", 4) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  c:step({ actionPressed = true }) -- skip page 1 reveal
  c:step({ actionPressed = true }) -- advance to page 2
  Assert.equal(c:status().pageIndex, 2)
  -- Held Action alone must not skip the second page: only reveal ticks count.
  for _ = 1, 6 do
    c:step({ actionDown = true })
  end
  Assert.equal(c:status().pageIndex, 2)
  Assert.equal(c:status().state, "WAITING_CLOSE")
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.final_action_closes_and_completes_exactly_once()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local completed = 0
  local result
  local handle = c:open(request("t", message()))
  handle:onComplete(function(r)
    completed = completed + 1
    result = r
  end)
  c:step({})
  c:step({ actionPressed = true }) -- skip reveal
  Assert.equal(c:status().state, "WAITING_CLOSE")
  c:step({ actionPressed = true }) -- to CLOSING
  Assert.equal(c:status().state, "CLOSING")
  c:step({}) -- CLOSING -> CLOSED, dispatch
  Assert.equal(c:status().state, "CLOSED")
  Assert.equal(completed, 1)
  Assert.equal(result.kind, "complete")
  Assert.equal(result.bankId, 543)
  Assert.equal(result.messageId, 5)
  Assert.equal(result.requestId, "t")
  c:step({ actionPressed = true })
  Assert.equal(completed, 1, "no second completion")
end

function T.open_consumes_the_initiating_edge()
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2) }) }, "prompt"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  -- The opener consumes the edge that opened the dialogue; the first step
  -- carries only held state, so nothing is skipped or advanced.
  local handle = c:open(request("t", message()))
  c:step({ actionDown = true })
  Assert.equal(c:status().state, "REVEALING")
  Assert.equal(c:status().revealedGlyphs, 0)
  c:step({ actionDown = true })
  Assert.equal(c:status().revealedGlyphs, 1)
  c:step({ actionPressed = true })
  Assert.equal(c:status().revealedGlyphs, 2)
  Assert.equal(c:status().pageIndex, 1)
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
end

function T.auto_scroll_pages_advance_without_action()
  local c = controller({
    page({ line({ glyph("A", 1), glyph("B", 2) }) }, "line"),
    page({ line({ glyph("C", 3) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  c:step({})
  c:step({})
  c:step({})
  Assert.equal(c:status().pageIndex, 2)
  Assert.equal(c:status().state, "REVEALING")
  c:step({})
  c:step({})
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

function T.zero_glyph_pages_reach_boundary_without_ticks()
  local c = controller({
    page({ line({ { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 } } }) }, "prompt"),
    page({ line({ glyph("A", 1) }) }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  Assert.equal(c:status().state, "WAITING_BOUNDARY", "zero-glyph page waits immediately")
end

function T.empty_message_closes_safely_on_open()
  local c = controller({})
  local completed = 0
  local handle = c:open(request("t", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  Assert.isTrue(c:isModal(), "modal ownership engages so the session drives close")
  c:step({})
  Assert.equal(completed, 1, "empty message completes on its first step")
  Assert.isFalse(c:isModal())
  Assert.equal(c:status().state, "CLOSED")
  c:step({})
  Assert.equal(completed, 1, "no second completion")
end

function T.malformed_message_fires_error_once_and_stays_closed()
  local c = FieldDialogueController.new({
    layout = function()
      error(Errors.new("FONT_GLYPH_MISSING", "fixture layout failure", { code = 0x9999 }))
    end,
  })
  local errors = 0
  local handle = c:open(request("t", message()))
  handle:onError(function(result)
    errors = errors + 1
    Assert.equal(result.kind, "error")
    Assert.notNil(result.error)
  end)
  Assert.isTrue(c:isModal(), "modal engages for one tick so the session drives the error")
  c:step({})
  Assert.equal(errors, 1)
  Assert.isFalse(c:isModal(), "the error releases modal ownership")
  c:step({})
  Assert.equal(errors, 1, "no second error dispatch")
  -- A subsequent valid open works.
  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local done = false
  local h2 = c2:open(request("t2", message()))
  h2:onComplete(function()
    done = true
  end)
  c2:step({})
  c2:step({ actionPressed = true })
  c2:step({ actionPressed = true })
  c2:step({})
  Assert.isTrue(done, "second dialogue completes")
end

function T.cancel_ignored_unless_allow_cancel()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  c:step({ cancelPressed = true })
  Assert.isTrue(c:isModal(), "cancel is ignored by default")

  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local cancelled = 0
  local result
  local handle = c2:open(request("t", message(), true))
  handle:onCancel(function(r)
    cancelled = cancelled + 1
    result = r
  end)
  c2:step({ cancelPressed = true })
  Assert.equal(cancelled, 1)
  Assert.equal(result.kind, "cancel")
  Assert.isFalse(c2:isModal())
  c2:step({ cancelPressed = true })
  Assert.equal(cancelled, 1, "cancel fires exactly once")
end

function T.close_is_idempotent_and_dispose_cancels()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local completed = 0
  local handle = c:open(request("t", message()))
  handle:onComplete(function()
    completed = completed + 1
  end)
  local result = assert(c:close())
  Assert.equal(result.kind, "complete")
  Assert.equal(completed, 1)
  Assert.isNil(c:close(), "second close is a no-op")
  Assert.equal(completed, 1)

  local c2 = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  local cancelled = 0
  local h2 = c2:open(request("t", message()))
  h2:onCancel(function()
    cancelled = cancelled + 1
  end)
  Assert.notNil(c2:dispose())
  Assert.equal(cancelled, 1)
  Assert.isNil(c2:dispose(), "second dispose is a no-op")
  Assert.equal(cancelled, 1)
end

function T.callback_can_queue_a_next_dialogue_but_not_step_it()
  local c = controller({
    page({ line({ glyph("A", 1) }) }, "eos"),
    page({ line({ glyph("B", 1) }) }, "eos"),
  })
  local second = false
  local handle = c:open(request("first", message()))
  handle:onComplete(function()
    local h2 = c:open(request("second", message()))
    h2:onComplete(function()
      second = true
    end)
    Assert.equal(c:status().state, "OPENING")
  end)
  c:step({})
  c:step({ actionPressed = true }) -- skip reveal
  c:step({ actionPressed = true }) -- to CLOSING
  c:step({}) -- dispatch: callback opens the second dialogue
  Assert.equal(c:status().state, "OPENING")
  Assert.isTrue(c:isModal(), "second dialogue owns input immediately")
  c:step({})
  c:step({ actionPressed = true })
  c:step({ actionPressed = true })
  c:step({})
  Assert.isTrue(second, "second dialogue completes on later ticks")
end

function T.cursor_blink_is_deterministic()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "prompt") }, { cursorBlinkTicks = 3 })
  c:open(request("t", message()))
  c:step({}) -- open -> revealing
  c:step({}) -- reveal the glyph, wait begins
  Assert.equal(c:status().state, "WAITING_BOUNDARY")
  local pattern = {}
  for _ = 1, 8 do
    c:step({})
    pattern[#pattern + 1] = c:status().cursorOn
  end
  Assert.deepEqual(pattern, { true, true, true, false, false, false, true, true })
end

function T.open_while_modal_raises()
  local c = controller({ page({ line({ glyph("A", 1) }) }, "eos") })
  c:open(request("t", message()))
  local err = Assert.throws(function()
    c:open(request("t2", message()))
  end)
  Assert.isTrue(Errors.is(err) and err.code == "DIALOGUE_ALREADY_OPEN", "raises DIALOGUE_ALREADY_OPEN")
  c:close()
  local h2 = c:open(request("t2", message()))
  Assert.notNil(h2)
end

function T.status_exposes_visible_lines_up_to_the_reveal()
  local c = controller({
    page({
      line({ glyph("A", 1), glyph("B", 2), glyph("C", 3) }),
      line({ glyph("D", 4), glyph("E", 5) }),
    }, "eos"),
  })
  c:open(request("t", message()))
  c:step({})
  Assert.equal(#c:status().visibleLines, 0, "nothing revealed yet")
  c:step({})
  Assert.equal(#c:status().visibleLines, 1)
  Assert.equal(#c:status().visibleLines[1], 1, "first line shows the first glyph")
  c:step({})
  c:step({})
  Assert.equal(#c:status().visibleLines[1], 2)
  c:step({})
  c:step({})
  Assert.equal(#c:status().visibleLines[1], 3)
  c:step({})
  c:step({})
  Assert.equal(#c:status().visibleLines, 2, "second line starts after the first fills")
  Assert.equal(#c:status().visibleLines[2], 1)
  c:step({})
  c:step({})
  Assert.equal(#c:status().visibleLines[2], 2)
  Assert.equal(c:status().state, "WAITING_CLOSE")
end

return T
