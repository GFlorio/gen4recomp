-- Pinned HGSS signpost window command catalog: the five MAPSIGNCOMMAND_*
-- values (0..4) opcodes 57/58 decode. The decomp's C sources name the
-- commands in include/constants/scrcmd.h (`MAPSIGNCOMMAND_NOP`..`HIDE`);
-- at the pinned asm-era commit the same five commands are the
-- Signpost_DoCurrentCommand jump-table cases in asm/signpost.s. The script
-- corpus itself carries these values: SetSignpostAction 3/2/4 and the
-- std_signpost sequence rely on the exact numbering. Pure data; no love
-- dependency.
return {
  schema = 1,
  source = {
    repo = "pret/pokeheartgold",
    commit = "dfdbbdf3273545ca35456d69bcb0ee3403f76450",
    inputs = {
      {
        path = "asm/signpost.s",
        sha256 = "bdb17ae49d8332bcc472e7848a2ef5d08293b81707cd8aaaa92e119c3a5b0f43",
      },
    },
  },
  byCode = {
    [0] = { name = "MAPSIGNCOMMAND_NOP" },
    [1] = { name = "MAPSIGNCOMMAND_SHOW" },
    [2] = { name = "MAPSIGNCOMMAND_WIPE_OUT" },
    [3] = { name = "MAPSIGNCOMMAND_WIPE_IN" },
    [4] = { name = "MAPSIGNCOMMAND_HIDE" },
  },
}
