-- Headless tests for AnimationDebugOverlayView: the developer keybindings
-- and selection state of the in-game animation debugging overlays (spec
-- section 39). The view's key handling is a pure state machine over a scene
-- runtime -- only the draw functions touch love.graphics, so everything
-- here runs without a graphics context. Snapshot entries are copies: after a
-- control key the tests re-snapshot through the view's own selection rule.

local Assert = require("tests.support.Assert")
local AnimationDebugger = require("libs.engine.src.AnimationDebugger")
local GenericModelFixture = require("tests.support.GenericModelFixture")
local ModelInstance = require("libs.engine.src.ModelInstance")
local AnimationDebugOverlayView = require("game.src.game.AnimationDebugOverlayView")

local T = {}

local function newInstance(opts)
  opts = opts or {}
  local instance = ModelInstance.new(GenericModelFixture.doorDefinition(), { transform = opts.transform })
  if opts.play then
    instance:play(opts.play)
  end
  if opts.advance then
    for _ = 1, opts.advance do
      instance:updateFixed()
    end
  end
  if opts.pose ~= false then
    instance:evaluatePose()
  end
  return instance
end

local function runtimeWith(instances)
  return { animatedInstances = instances }
end

-- The view's selection rule: the entry of the selected clip, or the first
-- entry before a clip is selected.
local function selectedEntry(view, instance)
  local entries = AnimationDebugger.snapshot(instance)
  if view.selectedClip then
    for _, entry in ipairs(entries) do
      if entry.clipName == view.selectedClip then
        return entry
      end
    end
  end
  return entries[1]
end

function T.f3_toggles_the_overlay()
  local view = AnimationDebugOverlayView.new()
  Assert.isFalse(view.enabled)
  Assert.isTrue(view:keypressed("f3", runtimeWith({})))
  Assert.isTrue(view.enabled)
  Assert.isTrue(view:keypressed("f3", runtimeWith({})))
  Assert.isFalse(view.enabled)
end

function T.keys_are_ignored_while_disabled()
  local view = AnimationDebugOverlayView.new()
  Assert.isFalse(view:keypressed("p", runtimeWith({ newInstance({ play = "DoorOpen" }) })))
  Assert.isFalse(view:keypressed("f4", runtimeWith({ newInstance() })))
  Assert.isFalse(view:keypressed("n", runtimeWith({})))
end

function T.f4_cycles_the_selected_instance()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a, b = newInstance(), newInstance()
  local runtime = runtimeWith({ a, b })
  Assert.equal(view.selectedIndex, 0)
  Assert.isTrue(view:keypressed("f4", runtime))
  Assert.equal(view.selectedIndex, 1)
  Assert.isTrue(view:keypressed("f4", runtime))
  Assert.equal(view.selectedIndex, 0, "cycles back to the first instance")
end

function T.f4_resets_the_selected_clip()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen" })
  view:keypressed("f5", runtimeWith({ a }))
  Assert.equal(view.selectedClip, "DoorOpen")
  view:keypressed("f4", runtimeWith({ a, newInstance() }))
  Assert.equal(view.selectedClip, nil, "a new instance starts at its first clip")
end

function T.f5_cycles_the_selected_clip()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen" })
  local runtime = runtimeWith({ a })
  Assert.equal(view.selectedClip, nil)
  view:keypressed("f5", runtime)
  Assert.equal(view.selectedClip, "DoorOpen", "the first f5 selects the first clip")
  view:keypressed("f5", runtime)
  Assert.equal(view.selectedClip, "DoorClose")
  view:keypressed("f5", runtime)
  Assert.equal(view.selectedClip, "blink")
  view:keypressed("f5", runtime)
  Assert.equal(view.selectedClip, "DoorOpen", "wraps to the first clip")
end

function T.p_toggles_play_and_pause_of_the_selected_clip()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen", advance = 2 })
  local runtime = runtimeWith({ a })
  Assert.isTrue(selectedEntry(view, a).playing)
  Assert.isTrue(view:keypressed("p", runtime))
  Assert.isTrue(selectedEntry(view, a).paused, "p pauses the playing clip")
  Assert.isTrue(view:keypressed("p", runtime))
  Assert.isFalse(selectedEntry(view, a).paused, "p resumes the paused clip")
end

function T.brackets_seek_the_selected_clip()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen", advance = 2 })
  local runtime = runtimeWith({ a })
  Assert.equal(selectedEntry(view, a).frame, 2)
  Assert.isTrue(view:keypressed("]", runtime))
  Assert.equal(selectedEntry(view, a).frame, 3, "] seeks forward one frame")
  Assert.isTrue(view:keypressed("[", runtime))
  Assert.equal(selectedEntry(view, a).frame, 2, "[ seeks back one frame")
  -- The player clamps at the inclusive max frame ((frameCount << 12) - 1):
  -- 20 seeks forward stop there.
  for _ = 1, 20 do
    view:keypressed("]", runtime)
  end
  Assert.equal(selectedEntry(view, a).frame, (8 * 4096 - 1) / 4096)
end

function T.comma_and_period_set_the_direction()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen", advance = 2 })
  local runtime = runtimeWith({ a })
  Assert.equal(selectedEntry(view, a).direction, "forward")
  Assert.isTrue(view:keypressed(",", runtime))
  Assert.equal(selectedEntry(view, a).direction, "reverse")
  Assert.isTrue(view:keypressed(".", runtime))
  Assert.equal(selectedEntry(view, a).direction, "forward")
end

function T.l_cycles_the_loop_mode()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen" })
  local runtime = runtimeWith({ a })
  Assert.isTrue(view:keypressed("l", runtime))
  Assert.equal(selectedEntry(view, a).loopMode, "once")
  Assert.isTrue(view:keypressed("l", runtime))
  Assert.equal(selectedEntry(view, a).loopMode, "loop")
end

function T.n_and_m_toggle_the_axis_visualizations()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  Assert.isFalse(view.showNodeAxes)
  Assert.isTrue(view:keypressed("n", runtimeWith({})))
  Assert.isTrue(view.showNodeAxes)
  Assert.isTrue(view:keypressed("m", runtimeWith({})))
  Assert.isTrue(view.showSlotAxes)
  Assert.isTrue(view:keypressed("n", runtimeWith({})))
  Assert.isFalse(view.showNodeAxes)
end

function T.clip_keys_are_ignored_without_an_instance()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local runtime = runtimeWith({})
  Assert.isFalse(view:keypressed("f4", runtime))
  Assert.isFalse(view:keypressed("f5", runtime))
  Assert.isFalse(view:keypressed("p", runtime))
  Assert.isFalse(view:keypressed("]", runtime))
  Assert.isFalse(view:keypressed(".", runtime))
  Assert.isFalse(view:keypressed("l", runtime))
end

-- LÖVE's KeyConstant names for punctuation vary across versions and
-- platforms; the view normalizes them.
function T.punctuation_key_aliases_work()
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen", advance = 2 })
  local runtime = runtimeWith({ a })
  Assert.equal(selectedEntry(view, a).frame, 2)
  Assert.isTrue(view:keypressed("right bracket", runtime))
  Assert.equal(selectedEntry(view, a).frame, 3)
  Assert.isTrue(view:keypressed("left bracket", runtime))
  Assert.equal(selectedEntry(view, a).frame, 2)
  Assert.isTrue(view:keypressed("period", runtime))
  Assert.equal(selectedEntry(view, a).direction, "forward")
  Assert.isTrue(view:keypressed("comma", runtime))
  Assert.equal(selectedEntry(view, a).direction, "reverse")
end

function T.controls_fall_back_to_the_first_entry_when_the_clip_vanishes()
  -- The selected clip can disappear from the snapshot (the animation is
  -- stopped mid-overlay); the controls fall back to the first entry instead
  -- of failing.
  local view = AnimationDebugOverlayView.new()
  view:keypressed("f3", runtimeWith({}))
  local a = newInstance({ play = "DoorOpen", advance = 2 })
  local runtime = runtimeWith({ a })
  view:keypressed("f5", runtime) -- select DoorClose (not playing)
  a:stop("DoorClose")
  Assert.isTrue(view:keypressed("p", runtime), "p still consumed on the fallback entry")
  Assert.isTrue(selectedEntry(view, a).paused)
end

return T
