-- Handwritten demo override (script override system): the high-level sign
-- mod API. A sign and a Trainer Tip run through S.sign / S.trainerTip with
-- the built-in semantic appearances (sign, trainer_tip) and no source-only
-- type/map data; the messages are the real New Bark sign texts from the
-- generated message bank 542.

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
