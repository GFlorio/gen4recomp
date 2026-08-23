local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.engine.src.DialoguePresentationLayout")

local T = {}

function T.computes_centered_bottom_aligned_local_geometry()
  local presentation = DialoguePresentationLayout.compute({ x = 37, y = 11, width = 900, height = 420 })
  Assert.near(presentation.scale, 900 / 256, 1e-9)
  Assert.deepEqual(
    presentation.origin,
    { x = 37 + (900 - 256 * presentation.scale) / 2, y = 11 + 420 - 48 * presentation.scale }
  )
  Assert.deepEqual(presentation.box, { x = 16, y = 8, width = 216, height = 32 })
  Assert.deepEqual(presentation.text, { x = 26, y = 8, width = 196, height = 32 })
  Assert.deepEqual(presentation.outerRect, {
    x = presentation.origin.x,
    y = presentation.origin.y,
    width = 256 * presentation.scale,
    height = 48 * presentation.scale,
  })
end

function T.exact_scale_and_cap_are_validated()
  local exact = DialoguePresentationLayout.compute({ x = 0, y = 0, width = 640, height = 480 }, { scale = 2 })
  Assert.equal(exact.scale, 2)
  local capped = DialoguePresentationLayout.compute({ x = 0, y = 0, width = 640, height = 480 }, { maxScale = 1.5 })
  Assert.equal(capped.scale, 1.5)
  Assert.isFalse(pcall(function()
    DialoguePresentationLayout.compute({ x = 0, y = 0, width = 100, height = 100 }, { scale = 1 })
  end))
end

return { tests = T }
