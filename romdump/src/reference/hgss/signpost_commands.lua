-- Pinned HGSS signpost window command catalog: the five MAPSIGNCOMMAND_*
-- values (0..4) opcodes 57/58 decode. The decomp's C sources name the
-- commands in include/constants/scrcmd.h (`MAPSIGNCOMMAND_NOP`..`HIDE`);
-- at the pinned asm-era commit the same five commands are the
-- Signpost_DoCurrentCommand jump-table cases in asm/signpost.s. The script
-- corpus itself carries these values: SetSignpostAction 3/2/4 and the
-- std_signpost sequence rely on the exact numbering. Pure data; no love
-- dependency.

local M = {
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

-- The semantic command enum string (nop/show/wipe_out/wipe_in/hide) for a
-- raw MAPSIGNCOMMAND_* code, or nil when the code is not one of the five
-- pinned commands. Unknown codes are malformed source at lowering; nothing
-- ever defaults to nop.
---@param code any
---@return string|nil
function M.semanticName(code)
  local entry = M.byCode[code]
  if type(entry) ~= "table" then
    return nil
  end
  local semantic = entry.name:match("^MAPSIGNCOMMAND_([A-Z_]+)$")
  if semantic == nil then
    return nil
  end
  return semantic:lower()
end

return M
