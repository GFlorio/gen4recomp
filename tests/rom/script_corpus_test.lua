-- ROM-gated script-corpus verification: decodes every scr_seq member of the
-- real dump in one traversal, validates the produced semantic scripts, and
-- pins the closed sound-opcode partition and opcode 726 soundplate lowering.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local Verifier = require("romdump.src.digest.script.Verifier")
local S = require("gen4.script")

local T = {}

local SUPPORTED_OPS = { 73, 74, 75, 78, 79, 80, 81, 82, 84, 85, 87, 726 }
local CRY_OPS = { 76, 77, 89, 90, 91, 92 }
local ABSENT_OPS = { 83, 86, 88, 93, 544, 575, 664, 665, 666 }
local REACHABLE_EXCLUDED_OPS = { 218, 779 }
local SOUND_NAME_KEYWORDS = { "SE", "BGM", "Fanfare", "Cry", "Chatot", "Music", "Sound" }

local ALLOWED_REACHABLE_SOUND = {}
for _, op in ipairs(SUPPORTED_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end
for _, op in ipairs(CRY_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end
for _, op in ipairs(REACHABLE_EXCLUDED_OPS) do
  ALLOWED_REACHABLE_SOUND[op] = true
end

local function soundRelated(name)
  for _, keyword in ipairs(SOUND_NAME_KEYWORDS) do
    if name:find(keyword, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function scrub(step)
  step.movementComplete = nil
  step.movementUnsupported = nil
  step.yieldsNextTick = nil
  step.sourceNotes = nil
end

T["corpus decodes validates and sound partition remains closed"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)

  local scriptCount = 0
  local decodeNotes = 0
  local problems = {}
  local reachable = {}
  local raw726 = 0
  local unsupported726 = 0
  local semanticCount = 0

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
    for _, ins in ipairs(script.instructions) do
      local sites = reachable[ins.opcode]
      if sites == nil then
        sites = {}
        reachable[ins.opcode] = sites
      end
      if #sites < 3 then
        sites[#sites + 1] = ("member %d script %d offset 0x%04X"):format(member, script.index, ins.offset)
      end
      if ins.opcode == 726 then
        raw726 = raw726 + 1
      end
    end
    if lowered.unsupported then
      for _, node in ipairs(lowered.unsupported) do
        if node.command == 726 then
          unsupported726 = unsupported726 + 1
        end
      end
    end
    FieldScripts.eachStep(steps, function(step)
      if step.op == "process_soundplate" then
        semanticCount = semanticCount + 1
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

  local missing = {}
  for _, op in ipairs(SUPPORTED_OPS) do
    if reachable[op] == nil then
      missing[#missing + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#missing, 0, "supported sound opcodes have no retail callsite: " .. table.concat(missing, ", "))

  local diverged = {}
  for _, op in ipairs(ABSENT_OPS) do
    if reachable[op] ~= nil then
      diverged[#diverged + 1] = CommandCatalog.name(op)
        .. " ("
        .. tostring(op)
        .. ") at "
        .. table.concat(reachable[op], "; ")
    end
  end
  Assert.equal(#diverged, 0, "unsupported sound opcodes reached the retail corpus: " .. table.concat(diverged, " || "))

  local gone = {}
  for _, op in ipairs(REACHABLE_EXCLUDED_OPS) do
    if reachable[op] == nil then
      gone[#gone + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#gone, 0, "reachable-excluded sound opcodes lost their retail callsites: " .. table.concat(gone, ", "))

  local unexpected = {}
  for op, sites in pairs(reachable) do
    if not ALLOWED_REACHABLE_SOUND[op] and soundRelated(CommandCatalog.name(op)) then
      unexpected[#unexpected + 1] = CommandCatalog.name(op)
        .. " ("
        .. tostring(op)
        .. ") at "
        .. table.concat(sites, "; ")
    end
  end
  Assert.equal(
    #unexpected,
    0,
    "sound-related field opcodes outside the closed partition: " .. table.concat(unexpected, " || ")
  )

  Assert.isTrue(raw726 >= 1, "retail corpus must reach opcode 726")
  Assert.equal(unsupported726, 0, "no 726 callsite may lower as unsupported")
  Assert.isTrue(semanticCount >= 1, "at least one semantic process_soundplate must originate from 726")
  Assert.equal(semanticCount, raw726, "every raw 726 callsite must survive as a semantic process_soundplate")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
