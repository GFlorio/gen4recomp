-- Public Script API v1 example: a semantic field choice with stable results.
-- Mods load `gen4.script`; they never construct presentation objects or pass
-- callbacks into scripts.

local S = require("gen4.script")

return S.script({
  api = 1,
  id = "example.semantic_menu",
  steps = {
    S.choose({
      items = {
        S.choice("Take", 10),
        S.choice("Leave", 20),
      },
      result = S.var("choice"),
      cancellable = true,
      cancelValue = 20,
      placement = { mode = "auto", anchor = "auto", surface = "auto" },
    }),
    S.stop(),
  },
})
