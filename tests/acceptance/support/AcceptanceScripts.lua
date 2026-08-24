-- Script resources used only by acceptance composition. They are installed
-- through the normal validated override path and never live in production
-- data or the normal runtime registry.

return {
  ["demo.signpost"] = [[
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "demo.signpost",
  steps = {
    S.sign({
      message = "msg.hgss.0542.00034",
      appearance = "sign",
    }),
    S.trainerTip({
      message = "msg.hgss.0542.00036",
      appearance = "trainer_tip",
    }),
    S.stop(),
  },
})
]],
}
