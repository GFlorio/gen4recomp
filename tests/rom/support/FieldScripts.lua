-- Shared decode/walk helpers for ROM suites that consume the real field-script
-- corpus: opens scr_seq.narc and decodes every member through the production
-- decoder, then walks the structured steps of each script (lowering and
-- structuring included) so the corpus pass is defined once.

local FieldScripts = {}

---@param romFs table
---@return table archive
---@return table[] memberIrs
function FieldScripts.decode(romFs)
  local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
  local ScriptMembers = require("romdump.src.reference.hgss.script_members")
  local archive = assert(romFs:openNarc("field_scripts"))
  local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, "romfs/scr_seq.narc", {
    sounds = require("romdump.src.reference.hgss.sndseq").byId,
    flags = require("romdump.src.reference.hgss.flags").byId,
    vars = require("romdump.src.reference.hgss.vars").byId,
    maps = require("romdump.src.reference.hgss.maps").byId,
    spawns = require("romdump.src.reference.hgss.spawns").byId,
  })
  return archive, memberIrs
end

---@param archive table
---@param memberIrs table[]
---@param fn fun(member: integer, index: integer, steps: table[], lowered: table)
function FieldScripts.eachScript(archive, memberIrs, fn)
  local stdCatalog = require("romdump.src.digest.script.SourceCatalog").catalog()
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local Structurer = require("romdump.src.digest.script.Structurer")
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for index, script in pairs(ir.scripts) do
        local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
        fn(member, index, Structurer.structure(lowered, index), lowered)
      end
    end
  end
end

---@param items table[]
---@param fn fun(step: table)
function FieldScripts.eachStep(items, fn)
  for _, item in ipairs(items) do
    if item.op == "if" then
      FieldScripts.eachStep(item.yes, fn)
      FieldScripts.eachStep(item.no, fn)
    elseif item.op == "switch" then
      for _, caseSteps in pairs(item.cases) do
        FieldScripts.eachStep(caseSteps, fn)
      end
      FieldScripts.eachStep(item.default, fn)
    else
      fn(item)
    end
  end
end

return FieldScripts
