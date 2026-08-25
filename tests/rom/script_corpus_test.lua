-- ROM-gated script-corpus verification: decodes every scr_seq member of the
-- real dump, translates and validates every script, and pins the vertical-
-- slice goldens (elms-lab script 0, the lab sign, the New Bark woman). The
-- decoder must never drift (no decode notes), every resource must validate,
-- and the verifier must never fault.

local Assert = require("tests.support.Assert")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local S = require("gen4.script")

local T = {}

local function scrub(step)
  step.movementComplete = nil
  step.movementUnsupported = nil
  step.yieldsNextTick = nil
  step.sourceNotes = nil
end

-- 1. The whole corpus decodes without drift, translates without unexpected
-- verifier faults, and every resource validates. The one known verifier
-- finding is the bug-contest script's Return reachable at call-stack height
-- zero (member 151 script 5, the retail's own structure, also present in the
-- pinned scr_seq_0151.s reconstruction).
-- The audio-op census rides the same pass: temporary music, cries, and cry
-- waits are all reachable in retail field scripts, so the production
-- service must execute each of them -- none may be rejected at import, and
-- none may fail only when executed.
T["corpus decodes and validates"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local scriptCount = 0
  local decodeNotes = 0
  local problems = {}
  local audioOpCounts = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index, steps, lowered)
    scriptCount = scriptCount + 1
    local script = memberIrs[member].scripts[index]
    if script.decodeNote ~= nil then
      decodeNotes = decodeNotes + 1
    end
    local report = Verifier.verifyScript(steps, script, memberIrs[member], lowered.omissions)
    if not report.ok then
      problems[#problems + 1] = { member = member, scriptIndex = index, messages = report.problems }
    end
    FieldScripts.eachStep(steps, function(step)
      if step.op == "temporary_music" or step.op == "play_cry" or step.op == "wait_cry" then
        audioOpCounts[step.op] = (audioOpCounts[step.op] or 0) + 1
      end
    end)
    FieldScripts.eachStep(steps, scrub)
    local ok, err = S.validate({ api = 1, id = "check", steps = steps })
    if not ok then
      error("script " .. member .. "/" .. index .. " fails validation: " .. tostring(err))
    end
  end)
  Assert.isTrue(scriptCount > 2000, "expected the full script corpus")
  Assert.equal(decodeNotes, 0)
  Assert.equal(#problems, 1)
  Assert.equal(problems[1].member, 151)
  Assert.equal(problems[1].scriptIndex, 5)
  Assert.isTrue((audioOpCounts.temporary_music or 0) >= 1, "retail field scripts reach temporary music")
  Assert.isTrue((audioOpCounts.play_cry or 0) >= 1, "retail field scripts reach cry playback")
  Assert.isTrue((audioOpCounts.wait_cry or 0) >= 1, "retail field scripts wait on cries")
end

-- 2. The vertical-slice goldens keep their canonical shapes: the elms-lab
-- script 0, the lab sign sequence, and the New Bark woman dialogue.
T["vertical-slice goldens"] = function(romFs)
  local _, memberIrs = FieldScripts.decode(romFs)
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
T["std member public ids"] = function(_)
  local stdCatalog = SourceCatalog.catalog()
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

-- 5. The signpost command family (55-60) decodes without losing operands on
-- the real corpus: every decoded operand of every signpost instruction equals
-- the member bytes at its offset, and the six opcodes all occur. The compiled
-- TrainerTipsEx and DirectionSignpostEx macro sequences and the std_signpost
-- common script are the pinned real-script fixtures the signpost runtime work
-- must keep byte- and sequence-faithful.
T["signpost contracts hold on the real corpus"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local stdCatalog = SourceCatalog.catalog()
  local vars = require("romdump.src.reference.hgss.vars").byId
  local varNameToId = {}
  for id, name in pairs(vars) do
    varNameToId[name] = id
  end

  local function byteValue(bytes, pos, width)
    local value = 0
    for i = 0, width - 1 do
      value = value + bytes:byte(pos + i) * (2 ^ (8 * i))
    end
    return value
  end

  local counts = {}
  local membersWithSignposts = {}
  -- DirectionSignpost (55) operand 2 and SetSignpostMap (56) operand 1 are
  -- both the signpost source `type` parameter (SemanticLowering's
  -- `sourceAppearance.type`). The generated field-UI asset config's
  -- `signposts.sourceTypes` claims to be "every signpost source type found
  -- in the corpus" -- this census is the one authoritative scan for that
  -- claim, replacing a hand-curated numeric-literal scan that previously
  -- swept up unrelated opcode parameters as if they were signpost types.
  local sourceTypes = {}
  for member, ir in pairs(memberIrs) do
    if ir ~= nil then
      for _, script in pairs(ir.scripts) do
        for _, ins in ipairs(script.instructions) do
          if ins.opcode >= 55 and ins.opcode <= 60 then
            counts[ins.opcode] = (counts[ins.opcode] or 0) + 1
            membersWithSignposts[member] = true
          end
          if ins.opcode == 55 then
            sourceTypes[ins.operands[2].raw] = true
          elseif ins.opcode == 56 then
            sourceTypes[ins.operands[1].raw] = true
          end
        end
      end
    end
  end
  for opcode = 55, 60 do
    Assert.isTrue((counts[opcode] or 0) > 0, "opcode " .. opcode .. " occurs in the corpus")
  end
  local sortedTypes = {}
  for t in pairs(sourceTypes) do
    sortedTypes[#sortedTypes + 1] = t
  end
  table.sort(sortedTypes)
  Assert.deepEqual(
    sortedTypes,
    { 0, 1, 2, 3 },
    "the real corpus's signpost source-type domain is exactly {0,1,2,3}; a new value here means "
      .. "romdump/src/config/FieldUiAssets.lua's sourceTypes must be updated to match, not defaulted around"
  )

  -- Operand preservation against the raw member bytes. The decoder renames
  -- var-range operands through the pinned vars catalog; every other operand
  -- must survive as the exact number it was encoded with.
  for member, _ in pairs(membersWithSignposts) do
    local bytes = assert(archive:readMember(member))
    for _, script in pairs(memberIrs[member].scripts) do
      for _, ins in ipairs(script.instructions) do
        if ins.opcode >= 55 and ins.opcode <= 60 then
          local widths = assert(CommandCatalog.widths(ins.opcode), "opcode " .. ins.opcode .. " has pinned widths")
          Assert.equal(#ins.operands, #widths, "opcode " .. ins.opcode .. " operand count")
          local expectedSize = 2
          for _, width in ipairs(widths) do
            expectedSize = expectedSize + width
          end
          Assert.equal(ins.size, expectedSize, "opcode " .. ins.opcode .. " instruction size")
          -- `ins.offset` is the zero-based opcode byte; `bytes:byte` is
          -- 1-based, so the first operand byte sits at ins.offset + 3.
          local pos = ins.offset + 3
          for index, width in ipairs(widths) do
            local encoded = byteValue(bytes, pos, width)
            local raw = ins.operands[index].raw
            if type(raw) == "number" then
              Assert.equal(raw, encoded, "opcode " .. ins.opcode .. " operand " .. index .. " preserved")
            else
              Assert.equal(
                varNameToId[raw],
                encoded,
                "opcode " .. ins.opcode .. " named operand " .. index .. " (" .. raw .. ") preserved"
              )
            end
            pos = pos + width
          end
        end
      end
    end
  end

  -- TrainerTipsEx compiles to SetSignpostMap type,0; SetSignpostAction
  -- WIPE_IN; WaitSignpostAction; TrainerTips; CallStd std_signpost.
  local tips = memberIrs[9].scripts[0]
  local function opSequence(script)
    local out = {}
    for _, ins in ipairs(script.instructions) do
      local operands = {}
      for _, operand in ipairs(ins.operands) do
        operands[#operands + 1] = operand.raw
      end
      out[#out + 1] = { opcode = ins.opcode, operands = operands }
    end
    return out
  end
  Assert.deepEqual(opSequence(tips), {
    { opcode = 56, operands = { 2, 0 } },
    { opcode = 57, operands = { 3 } },
    { opcode = 58, operands = {} },
    { opcode = 59, operands = { 0, "VAR_SPECIAL_RESULT" } },
    { opcode = 20, operands = { 2000 } },
    { opcode = 2, operands = {} },
  }, "the TrainerTipsEx compiled sequence")

  -- DirectionSignpostEx compiles to DirectionSignpost message,type,map,out;
  -- SetSignpostAction WIPE_IN; WaitSignpostAction; WaitSignpost;
  -- CallStd std_signpost. The opcode-55 out operand decodes but is unused.
  local direction = memberIrs[168].scripts[2]
  Assert.deepEqual(opSequence(direction), {
    { opcode = 55, operands = { 0, 1, 4, "VAR_SPECIAL_RESULT" } },
    { opcode = 57, operands = { 3 } },
    { opcode = 58, operands = {} },
    { opcode = 60, operands = { "VAR_SPECIAL_RESULT" } },
    { opcode = 20, operands = { 2000 } },
    { opcode = 2, operands = {} },
  }, "the DirectionSignpostEx compiled sequence")

  -- std_signpost (CallStd 2000) lives in member 3 script 0 and drives the
  -- wipe/hide cleanup from the special result: WIPE_OUT for results 0 and 2,
  -- HIDE for result 1 (directional dismissal).
  Assert.equal(SourceCatalog.commonPublicId(stdCatalog, 2000), "common.signpost")
  local located = stdCatalog.locate(2000)
  Assert.equal(located.member, 3)
  Assert.equal(located.scriptIndex, 0)
  local signpostScript = memberIrs[3].scripts[0]
  local commands = {}
  local waitSignpostCount = 0
  for _, ins in ipairs(signpostScript.instructions) do
    if ins.opcode == 57 then
      commands[#commands + 1] = ins.operands[1].raw
    elseif ins.opcode == 58 then
      Assert.equal(#ins.operands, 0)
    elseif ins.opcode == 60 then
      Assert.equal(ins.operands[1].raw, "VAR_SPECIAL_RESULT")
      waitSignpostCount = waitSignpostCount + 1
    end
  end
  Assert.deepEqual(commands, { 2, 2, 4 }, "std_signpost uses WIPE_OUT and HIDE")
  Assert.equal(waitSignpostCount, 1)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
