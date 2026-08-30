-- Source-independent identities for generated field-script resources. The
-- formatter is shared by ROM-derived producers and runtime consumers so an
-- ordinary vanilla script has one canonical project id.

local ScriptIdentity = {}

---@param scriptBankId number non-negative integer source script bank/member
---@param scriptIndex number non-negative zero-based compiled script index
---@return string
function ScriptIdentity.formatVanilla(scriptBankId, scriptIndex)
  assert(
    type(scriptBankId) == "number" and scriptBankId >= 0 and math.floor(scriptBankId) == scriptBankId,
    "script bank id must be a non-negative integer"
  )
  assert(
    type(scriptIndex) == "number" and scriptIndex >= 0 and math.floor(scriptIndex) == scriptIndex,
    "script index must be a non-negative integer"
  )
  return string.format("vanilla.hgss.scr_seq.%04d.script_%03d", scriptBankId, scriptIndex)
end

return ScriptIdentity
