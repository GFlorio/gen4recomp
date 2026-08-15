-- Handwritten demo override (script override system): the high-level sign
-- mod API. A custom-style sign and a Trainer Tip run through S.sign /
-- S.trainerTip with no source-only type/map data; the messages are the real
-- New Bark sign texts from the generated message bank 542. The custom style
-- id is registered per runtime before the window-style registry seals.

local S = require("gen4.script")

return S.script({
  api = 1,
  id = "demo.signpost",
  steps = {
    S.sign({
      message = "msg.hgss.0542.00034",
      appearance = "mod.route_sign",
    }),
    S.trainerTip({
      message = "msg.hgss.0542.00036",
      appearance = "trainer_tip",
    }),
    S.stop(),
  },
})
