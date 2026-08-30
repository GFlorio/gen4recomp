local Assert = require("tests.support.Assert")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")

local T = {
  metadata = {
    tags = { "dialogue", "cursor", "timing" },
  },
  tests = {},
}

local function waitingController()
  local tokensA = {
    { kind = "glyph", code = 1, text = "A", raw = { 1 } },
    { kind = "glyph", code = 1, text = "A", raw = { 1 } },
  }
  local controller = FieldDialogueController.new({
    layout = function()
      return {
        pages = {
          { lines = { { tokens = tokensA, width = 12 } }, breakKind = "prompt" },
          { lines = { { tokens = tokensA, width = 12 } }, breakKind = "eos" },
        },
        warnings = {},
        lineHeight = 16,
        lineSpacing = 0,
        textOriginX = 0,
        textOriginY = 0,
        contentWidth = 216,
        syntheticBreaks = 0,
      }
    end,
    policy = { interGlyphDelay = 0, glyphBudget = 2, abAcceleration = false },
    continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
  })
  controller:open({
    id = "timing",
    message = { bankId = 1, messageId = 1, text = "AA", tokens = tokensA, hadUnresolvedSubstitutions = false },
    allowCancel = false,
  })
  -- advance until waiting at the prompt boundary
  for _ = 1, 20 do
    local s = controller:status()
    if s.waiting then
      break
    end
    controller:step({})
  end
  return controller
end

local function phasesForSteps(controller, steps, drawBetween)
  local phases = {}
  phases[0] = controller:status().cursorPhase
  for tick = 1, steps do
    if drawBetween then
      for _ = 1, drawBetween do
        local _ = controller:status()
      end
    end
    controller:step({})
    phases[tick] = controller:status().cursorPhase
  end
  return phases
end

function T.tests.cursor_changes_only_every_nine_semantic_ticks()
  local c = waitingController()
  Assert.isTrue(c:status().waiting, "must be waiting for timing check")
  local phases = phasesForSteps(c, 45, 0)
  -- expected cycle 0,1,2,1 repeating every 9 ticks
  local cycle = { 0, 1, 2, 1 }
  local cycleLen = #cycle
  for tick = 0, 45 do
    local expectedIndex = math.floor(tick / 9) % cycleLen + 1
    local expected = cycle[expectedIndex]
    Assert.equal(
      phases[tick],
      expected,
      "phase at tick " .. tick .. " should be " .. expected .. " got " .. tostring(phases[tick])
    )
  end
end

function T.tests.draw_frequency_does_not_change_semantic_phase()
  local c1 = waitingController()
  local c2 = waitingController()
  local phasesEveryDraw = phasesForSteps(c1, 36, 1)
  local phasesBatched = phasesForSteps(c2, 36, 0)
  -- also test zero vs many draws: extra status queries must not advance
  for tick = 0, 36 do
    Assert.equal(phasesEveryDraw[tick], phasesBatched[tick], "phase must be independent of draw calls at tick " .. tick)
  end
  -- many draws between steps
  local c3 = waitingController()
  local phasesManyDraws = phasesForSteps(c3, 36, 5)
  for tick = 0, 36 do
    Assert.equal(phasesManyDraws[tick], phasesEveryDraw[tick], "many draws must not affect phase at tick " .. tick)
  end
end

function T.tests.new_wait_resets_phase_to_zero()
  local c = waitingController()
  Assert.equal(c:status().cursorPhase, 0, "first wait must start at phase 0")
  for _ = 1, 18 do
    c:step({})
  end
  local mid = c:status().cursorPhase
  Assert.isTrue(mid ~= 0, "after 18 ticks phase must have advanced")
  -- continue to next page
  c:step({ actionPressed = true })
  -- reveal next page until waiting again
  for _ = 1, 20 do
    if c:status().waiting then
      break
    end
    c:step({})
  end
  Assert.isTrue(c:status().waiting, "second page must be waiting")
  Assert.equal(c:status().cursorPhase, 0, "new wait must reset to phase 0")
  c:step({})
  Assert.equal(c:status().cursorPhase, 0, "first tick of new wait must stay 0")
end

function T.tests.off_by_one_boundaries()
  local c = waitingController()
  local phases = phasesForSteps(c, 40, 0)
  Assert.equal(phases[8], 0, "tick 8 must still be phase 0")
  Assert.equal(phases[9], 1, "tick 9 must advance to phase 1")
  Assert.equal(phases[17], 1, "tick 17 must stay phase 1")
  Assert.equal(phases[18], 2, "tick 18 must advance to phase 2")
  Assert.equal(phases[27], 1, "tick 27 must be phase 1 (cycle 0,1,2,1)")
  Assert.equal(phases[36], 0, "tick 36 must cycle back to 0")
end

function T.tests.drawing_without_semantic_step_leaves_state_unchanged()
  local c = waitingController()
  local before = c:status().cursorPhase
  for _ = 1, 100 do
    local _ = c:status()
  end
  Assert.equal(c:status().cursorPhase, before, "100 draws without step must not change phase")
end

function T.tests.continue_on_ninth_tick_does_not_double_advance()
  local c = waitingController()
  for _ = 1, 9 do
    c:step({})
  end
  Assert.equal(c:status().cursorPhase, 1, "at tick 9 phase is 1 before continue")
  c:step({ actionPressed = true })
  -- should have left waiting, not advanced extra
  Assert.isFalse(
    c:status().waiting and c:status().cursorPhase == 2,
    "continue on 9th tick must not cause extra phase tick"
  )
end

return T
