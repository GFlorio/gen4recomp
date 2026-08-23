local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.engine.src.DialoguePresentationLayout")

local T = {}

function T.field_exact_scale_keeps_the_dialogue_bottom_aligned()
  local ref = { x = 40, y = 20, width = 512, height = 384 }
  local layout = DialoguePresentationLayout.compute(ref, { scale = 2 })
  Assert.equal(layout.scale, 2)
  Assert.near(layout.origin.x, 40, 1e-9)
  Assert.near(layout.origin.y + layout.outerRect.height, ref.y + ref.height, 1e-9)
  Assert.deepEqual(layout.box, { x = 16, y = 8, width = 216, height = 32 })
end

function T.field_presentation_is_centered_in_translated_reference_frames()
  local ref = { x = 40, y = 20, width = 700, height = 500 }
  local layout = DialoguePresentationLayout.compute(ref, { scale = 1.5 })
  Assert.near(layout.origin.x + layout.outerRect.width / 2, ref.x + ref.width / 2, 1e-9)
  Assert.near(layout.origin.y + layout.outerRect.height, ref.y + ref.height, 1e-9)
end

return { tests = T }
