-- Checked-in generated overrides must retain newly supported source commands
-- as semantic operations instead of hiding them behind placeholder dialogue.

local Assert = require("tests.support.Assert")

local T = {}

local OVERRIDE_PATHS = {
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_017.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0843.script_012.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0843.script_013.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0845.script_001.lua",
}

local VISIBILITY_BY_OPCODE = { [746] = false, [747] = true }

local function assertAuxiliaryUiOperations(value, moduleName, seen)
  if type(value) ~= "table" then
    return
  end
  local opcodes = value.provenance and value.provenance.opcodes
  if opcodes then
    for _, opcode in pairs(opcodes) do
      if VISIBILITY_BY_OPCODE[opcode] ~= nil or opcode == 746 then
        Assert.equal(value.op, "set_auxiliary_ui_visible", moduleName .. " has an incorrect auxiliary UI operation")
        Assert.equal(
          value.visible,
          VISIBILITY_BY_OPCODE[opcode],
          moduleName .. " has an incorrect auxiliary UI visibility"
        )
        seen[opcode] = true
      end
    end
  end
  for _, child in pairs(value) do
    assertAuxiliaryUiOperations(child, moduleName, seen)
  end
end

function T.supported_auxiliary_ui_opcodes_are_semantic_operations_in_overrides()
  local seen = {}
  for _, path in ipairs(OVERRIDE_PATHS) do
    local chunk = assert(loadfile(path))
    assertAuxiliaryUiOperations(chunk(), path, seen)
  end
  Assert.isTrue(seen[746])
  Assert.isTrue(seen[747])
end

return T
