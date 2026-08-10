-- Override generator (the script override system): ports the structured
-- transcript of a script whose generated translation carries reachable
-- unsupported commands into a checked-in `data/scripts/overrides/<id>.lua`
-- override. The transform preserves every supported operation and control
-- edge; each maximal run of unsupported commands (and each call into a
-- common script that is itself unsupported) is replaced by one visible dummy
-- dialogue node so the interaction still does something in-game instead of
-- faulting. Output is deterministic: identical dumps produce byte-identical
-- override files. Pure domain module: no love dependency.

local S = require("gen4.script")
local Errors = require("libs.rom.src.Errors")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local LuaEmitter = require("romdump.src.digest.script.LuaEmitter")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local ScriptMembers = require("data.reference.hgss.script_members")

local OverrideGenerator = {}

-- The visible placeholder message every dummy dialogue node shows. It is a
-- project-owned reference the game's dialogue host resolves to a short
-- ellipsis; scripts never embed bulk text.
OverrideGenerator.PLACEHOLDER_MESSAGE = "msg.project.placeholder"

-- The generated transcripts overridden by the New Bark slice: member and
-- script index to the override's public id. The target table is a data
-- manifest (data/reference/hgss/script_override_targets.lua).
local TARGETS = require("data.reference.hgss.script_override_targets")

-- The common-script ids the transform may replace: every std script that is
-- itself unsupported, resolved once from the decoded corpus.
local function unsupportedCallTargets(memberIrs, stdCatalog)
  local targets = {}
  for member, ir in pairs(memberIrs) do
    for index, script in pairs(ir.scripts or {}) do
      local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
      local steps = Structurer.structure(lowered, index)
      local count = 0
      local function walk(items)
        for _, item in ipairs(items or {}) do
          if item.op == "if" then
            walk(item.yes)
            walk(item.no)
          elseif item.op == "unsupported" then
            count = count + 1
          end
        end
      end
      walk(steps)
      if count > 0 then
        targets[ScriptCompiler.publicId(member, index, stdCatalog)] = true
      end
    end
  end
  return targets
end

-- One visible dummy node replacing a run of unsupported commands (or an
-- unsupported call target): a short project placeholder dialogue.
---@param node table
---@return table
local function dummyNode(node)
  local dummy = { op = "say", message = OverrideGenerator.PLACEHOLDER_MESSAGE }
  if node.provenance ~= nil then
    dummy.provenance = node.provenance
  end
  return dummy
end

-- Replace every maximal run of consecutive `unsupported` ops in one linear
-- sequence with a single dummy node; `if`/`switch` bodies are walked
-- recursively. For background-triggered scripts, `face_player` on the
-- script's own object (self or a map index) is dropped: a background event
-- has no self object, so the source facing would fault at runtime. Returns a
-- fresh sequence (the input is never mutated).
---@param sequence table[]
---@param ctx table { unsupportedTargets, dropSelfFacing }
---@return table[]
local function transformSequence(sequence, ctx)
  local out = {}
  local runStart = nil
  local function flushRun()
    if runStart == nil then
      return
    end
    out[#out + 1] = dummyNode(runStart)
    runStart = nil
  end
  for _, step in ipairs(sequence) do
    if step.op == "unsupported" then
      if runStart == nil then
        runStart = step
      end
    else
      flushRun()
      if step.op == "if" then
        local copy = {}
        for key, value in pairs(step) do
          copy[key] = value
        end
        copy.yes = transformSequence(step.yes, ctx)
        copy.no = transformSequence(step.no, ctx)
        out[#out + 1] = copy
      elseif step.op == "face_player" and ctx.dropSelfFacing then
        local actor = step.actor
        -- A nil actor defaults to the script's own object (self).
        if
          actor == nil
          or type(actor) == "string"
          or (type(actor) == "table" and (actor.special == "self" or actor.mapIndex ~= nil))
        then
          -- No self object for a background trigger: drop the facing step.
        else
          out[#out + 1] = step
        end
      elseif
        (step.op == "call_common" or step.op == "call" or step.op == "goto_script")
        and ctx.unsupportedTargets[step.target or step.script]
      then
        out[#out + 1] = dummyNode(step)
      else
        out[#out + 1] = step
      end
    end
  end
  flushRun()
  return out
end

-- Decode the corpus the way the cache compiler does.
---@param romFs RomFs
---@return table memberIrs, table stdCatalog
local function decodeCorpus(romFs)
  local archive = assert(romFs:openNarc("field_scripts"))
  local stdCatalog = SourceCatalog.catalog()
  local catalog = {
    sounds = require("data.reference.hgss.sndseq").byId,
    flags = require("data.reference.hgss.flags").byId,
    vars = require("data.reference.hgss.vars").byId,
    maps = require("data.reference.hgss.maps").byId,
    spawns = require("data.reference.hgss.spawns").byId,
  }
  local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, "romfs/scr_seq.narc", catalog)
  return memberIrs, stdCatalog
end

-- Port one target script into an override resource.
---@param memberIr table
---@param scriptIndex integer
---@param target table { id, replaces? }
---@param stdCatalog table
---@param unsupportedTargets table<string, boolean>
---@return table resource
local function portScript(memberIr, scriptIndex, target, stdCatalog, unsupportedTargets)
  local script = memberIr.scripts[scriptIndex]
  local lowered = SemanticLowering.lowerScript(script, memberIr, { stdCatalog = stdCatalog })
  local steps = transformSequence(Structurer.structure(lowered, scriptIndex), {
    unsupportedTargets = unsupportedTargets,
    dropSelfFacing = target.backgroundTrigger == true,
  })
  ScriptCompiler.scrub(steps)
  local ok, validateErr = S.validate({ api = 1, id = "check", steps = steps })
  if not ok then
    error("ported override for " .. tostring(scriptIndex) .. " fails validation: " .. tostring(validateErr))
  end
  -- Coverage is the count of placeholder dialogues: every unsupported run
  -- (or unsupported call target) was replaced by one visible placeholder.
  local unsupportedCount = 0
  local function countPlaceholders(items)
    for _, item in ipairs(items or {}) do
      if item.op == "say" and item.message == OverrideGenerator.PLACEHOLDER_MESSAGE then
        unsupportedCount = unsupportedCount + 1
      elseif item.op == "if" then
        countPlaceholders(item.yes)
        countPlaceholders(item.no)
      end
    end
  end
  countPlaceholders(steps)
  local metadata = {
    override = true,
    generated = true,
    generator = { name = "hgss-script-translator", version = LuaEmitter.GENERATOR_VERSION },
    source = {
      repository = "g4recomp",
      path = memberIr.sourcePath,
      game = "heartgold",
      archive = "scr_seq",
      member = memberIr.member,
      scriptIndex = scriptIndex,
      sourceHash = "",
    },
    coverage = { complete = unsupportedCount == 0, unsupportedCount = unsupportedCount },
  }
  local resource = { api = 1, id = target.id, steps = steps, metadata = metadata }
  if target.replaces ~= nil then
    resource.replaces = target.replaces
  end
  return resource
end

-- Generate the override files for every target: `path` is repo-relative
-- (`data/scripts/overrides/<id>.lua`), `text` the emitted Lua module.
---@param romFs RomFs
---@return table[] files { id, path, text }
function OverrideGenerator.generate(romFs)
  assert(romFs and romFs.openNarc, "generate requires a RomFs-shaped object")
  local memberIrs, stdCatalog = decodeCorpus(romFs)
  local unsupportedTargets = unsupportedCallTargets(memberIrs, stdCatalog)
  local files = {}
  for member, indexes in pairs(TARGETS) do
    local memberIr = assert(memberIrs[member], "override target member " .. member .. " is not in the corpus")
    for scriptIndex, target in pairs(indexes) do
      assert(
        memberIr.scripts[scriptIndex] ~= nil,
        "override target member " .. member .. " script " .. scriptIndex .. " is not in the corpus"
      )
      local resource = portScript(memberIr, scriptIndex, target, stdCatalog, unsupportedTargets)
      local text = LuaEmitter.emitOverride(resource, {
        member = member,
        scriptIndex = scriptIndex,
        sourcePath = memberIr.sourcePath,
        replaces = target.replaces,
      })
      files[#files + 1] = {
        id = target.id,
        path = "data/scripts/overrides/" .. target.id .. ".lua",
        text = text,
      }
    end
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

return OverrideGenerator
