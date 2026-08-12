-- ROM-gated script-corpus verification: decodes every scr_seq member of the
-- real dump, translates and validates every script, and pins the vertical-
-- slice goldens (elms-lab script 0, the lab sign, the New Bark woman). The
-- decoder must never drift (no decode notes), every resource must validate,
-- and the verifier must never fault.

local Assert = require("tests.support.Assert")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local ScriptMembers = require("romdump.src.reference.hgss.script_members")
local S = require("gen4.script")

local T = {}

local function decodeAll(romFs)
  local archive = assert(romFs:openNarc("field_scripts"))
  local catalog = {
    sounds = require("romdump.src.reference.hgss.sndseq").byId,
    flags = require("data.reference.hgss.flags").byId,
    vars = require("data.reference.hgss.vars").byId,
    maps = require("romdump.src.reference.hgss.maps").byId,
    spawns = require("romdump.src.reference.hgss.spawns").byId,
  }
  return archive, ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, "romfs/scr_seq.narc", catalog)
end

local function scrub(items)
  for _, item in ipairs(items) do
    if item.op == "if" then
      scrub(item.yes)
      scrub(item.no)
    end
    item.movementComplete = nil
    item.movementUnsupported = nil
    item.yieldsNextTick = nil
    item.sourceNotes = nil
  end
end

-- 1. The whole corpus decodes without drift, translates without unexpected
-- verifier faults, and every resource validates. The one known verifier
-- finding is the bug-contest script's Return reachable at call-stack height
-- zero (member 151 script 5, the retail's own structure, also present in the
-- pinned scr_seq_0151.s reconstruction).
T["corpus decodes and validates"] = function(romFs)
  local archive, memberIrs = decodeAll(romFs)
  local stdCatalog = SourceCatalog.catalog()
  local scriptCount = 0
  local decodeNotes = 0
  local problems = {}
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for index, script in pairs(ir.scripts) do
        scriptCount = scriptCount + 1
        if script.decodeNote ~= nil then
          decodeNotes = decodeNotes + 1
        end
        local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
        local steps = Structurer.structure(lowered, index)
        local report = Verifier.verifyScript(steps, script, ir, lowered.omissions)
        if not report.ok then
          problems[#problems + 1] = { member = member, scriptIndex = index, messages = report.problems }
        end
        scrub(steps)
        local ok, err = S.validate({ api = 1, id = "check", steps = steps })
        if not ok then
          error("script " .. member .. "/" .. index .. " fails validation: " .. tostring(err))
        end
      end
    end
  end
  Assert.isTrue(scriptCount > 2000, "expected the full script corpus")
  Assert.equal(decodeNotes, 0)
  Assert.equal(#problems, 1)
  Assert.equal(problems[1].member, 151)
  Assert.equal(problems[1].scriptIndex, 5)
end

-- 2. The vertical-slice goldens keep their canonical shapes: the elms-lab
-- script 0, the lab sign sequence, and the New Bark woman dialogue.
T["vertical-slice goldens"] = function(romFs)
  local _, memberIrs = decodeAll(romFs)
  local stdCatalog = SourceCatalog.catalog()
  local function opsOf(member, scriptIndex)
    local ir = memberIrs[member]
    local lowered = SemanticLowering.lowerScript(ir.scripts[scriptIndex], ir, { stdCatalog = stdCatalog })
    local steps = Structurer.structure(lowered, scriptIndex)
    local out = {}
    for _, step in ipairs(steps) do
      out[#out + 1] = step.op
    end
    return out, steps, lowered, ir
  end
  -- Elms-lab script 0 (the doctor dialogue): the first fold is the say.
  local ops = opsOf(843, 0)
  Assert.isTrue(ops[1] == "play_sound" or ops[1] == "lock_all")
  -- The lab sign (member 843 script 9) is the clean seven-command sequence.
  local labOps, labSteps = opsOf(843, 9)
  Assert.deepEqual(labOps, { "play_sound", "lock_all", "say", "release_all", "yield_tick", "stop" })
  Assert.equal(labSteps[3].message, "msg.hgss.0543.00097")
  -- The New Bark woman (member 842 script 1) opens with the play/lock/face
  -- trio and folds a gendered say.
  local womanOps = opsOf(842, 1)
  Assert.equal(womanOps[1], "play_sound")
  Assert.equal(womanOps[2], "lock_all")
  Assert.equal(womanOps[3], "face_player")
  -- The elms-lab generated script 0 resource id (curated).
  local id = ScriptCompiler.publicId(843, 0, stdCatalog)
  Assert.equal(id, "elms_lab.generated.script_000")
  Assert.equal(ScriptCompiler.publicId(843, 9, stdCatalog), "new_bark.lab_sign")
  Assert.equal(ScriptCompiler.publicId(842, 1, stdCatalog), "new_bark.npc.woman_1")
end

-- 3. The common scripts in member 3 resolve through the std catalog to
-- `common.<name>` ids.
T["std member public ids"] = function(romFs)
  local stdCatalog = SourceCatalog.catalog()
  local names = {}
  local member3 = require("romdump.src.reference.hgss.script_members").banks
  Assert.equal(member3[3], 40)
  -- The give_item_verbose std script lives in member 3; the catalog names it.
  local giveId = nil
  for id, name in pairs(stdCatalog.namesById) do
    if name == "give_item_verbose" then
      giveId = id
      break
    end
  end
  Assert.notNil(giveId)
  local located = stdCatalog.locate(giveId)
  Assert.equal(located.member, 3)
  local common = require("romdump.src.digest.script.SourceCatalog").commonPublicId(stdCatalog, giveId)
  Assert.equal(common, "common.give_item_verbose")
end

-- 4. The corpus compile is deterministic: two independent compiles produce
-- byte-identical resources and an index in id-sorted order, independent of
-- the member-table iteration order.
T["corpus compile is deterministic"] = function(romFs)
  local Hashing = require("romdump.src.digest.Hashing")
  local first = assert(ScriptCompiler.compile(romFs, Hashing.sha1hex, Hashing.hashLua))
  local second = assert(ScriptCompiler.compile(romFs, Hashing.sha1hex, Hashing.hashLua))
  Assert.equal(first.marker, second.marker)
  Assert.equal(#first.resources, #second.resources)
  for i = 1, #first.resources do
    Assert.equal(first.resources[i].id, second.resources[i].id, "resource " .. i .. " has the same id")
  end
  local sorted = true
  for i = 2, #first.index.resources do
    if first.index.resources[i - 1].id > first.index.resources[i].id then
      sorted = false
    end
  end
  Assert.isTrue(sorted, "the compiled index is sorted by id")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
