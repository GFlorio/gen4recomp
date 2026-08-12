-- Override generator targets: the script-override set for the demo slice.
-- Each entry maps a scr_seq member/scriptIndex pair to the override's
-- public id; `replaces` names the generated base when the override id is
-- curated rather than identical; `backgroundTrigger` marks scripts whose
-- source opening faces the script's own object (a background trigger has no
-- self object, so the facing step is dropped). Project-owned data.
return {
  [842] = {
    [2] = { id = "vanilla.hgss.scr_seq.0842.script_002" },
    [7] = { id = "vanilla.hgss.scr_seq.0842.script_007" },
    [10] = { id = "vanilla.hgss.scr_seq.0842.script_010" },
    [11] = { id = "vanilla.hgss.scr_seq.0842.script_011" },
    [12] = { id = "vanilla.hgss.scr_seq.0842.script_012" },
    [13] = { id = "vanilla.hgss.scr_seq.0842.script_013" },
    [14] = { id = "vanilla.hgss.scr_seq.0842.script_014" },
    [16] = { id = "vanilla.hgss.scr_seq.0842.script_016" },
    [17] = { id = "vanilla.hgss.scr_seq.0842.script_017" },
  },
  [843] = {
    [0] = { id = "elms_lab.elm", replaces = "elms_lab.generated.script_000" },
    [3] = { id = "vanilla.hgss.scr_seq.0843.script_003" },
    [11] = { id = "vanilla.hgss.scr_seq.0843.script_011" },
    -- The starter machine and the healing PC are background events: their
    -- scripts open with a source FacePlayer on the script's own object,
    -- which a background trigger has no self for (the runtime would fault).
    -- The ported overrides drop those facing steps (marked backgroundTrigger).
    [12] = { id = "vanilla.hgss.scr_seq.0843.script_012", backgroundTrigger = true },
    [13] = { id = "vanilla.hgss.scr_seq.0843.script_013", backgroundTrigger = true },
  },
  [845] = {
    [1] = { id = "vanilla.hgss.scr_seq.0845.script_001" },
  },
  [846] = {
    [0] = { id = "vanilla.hgss.scr_seq.0846.script_000" },
  },
  [849] = {
    [0] = { id = "vanilla.hgss.scr_seq.0849.script_000" },
  },
}
