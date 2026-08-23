-- Project-owned projection of the no-follower Elm Lab entrance sequence.
-- Visible map obscuring is delegated to the field transition around the warp.
-- It keeps the source route's observable sound, warp, and event state.
local S = require("gen4.script")

return S.script {
  api = 1,
  id = "vanilla.hgss.scr_seq.0842.script_010",
  metadata = {
    override = true,
    generated = false,
    owner = "g4recomp",
    source = {
      repository = "g4recomp",
      path = "romfs/scr_seq.narc",
      game = "heartgold",
      archive = "scr_seq",
      member = 842,
      scriptIndex = 10,
    },
    coverage = { complete = true, unsupportedCount = 0 },
  },
  steps = {
    { op = "play_sound", sound = "SEQ_SE_DP_KAIDAN2" },
    { facing = "west", fieldX = 12, fieldZ = 6, map = "MAP_NEW_BARK_ELMS_LAB_2F", op = "warp", warp = 0 },
    { op = "wait_sound", sound = "SEQ_SE_DP_KAIDAN2" },
    { op = "set_var", value = 1, variable = "VAR_UNK_407C" },
    { op = "stop" },
  },
}
