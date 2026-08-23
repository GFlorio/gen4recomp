-- Handwritten acceptance fixture: exercise the production dialogue path with
-- a ROM-authored message that contains a source continuation control.
local S = require("gen4.script")

return S.script({
  api = 1,
  id = "demo.dialogue",
  steps = {
    S.say({ message = "msg.hgss.0542.00004" }),
    S.stop(),
  },
})
