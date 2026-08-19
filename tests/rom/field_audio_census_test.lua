-- ROM-gated retail sound-opcode census: enumerates every reachable field-script
-- opcode in the scrub corpus and pins the closed three-class audio
-- partition. SUPPORTED opcodes must keep retail callsites; ABSENT opcodes are
-- sound-related but proven unreachable and must never grow the runtime API;
-- REACHABLE_EXCLUDED opcodes are observed at retail callsites but belong to
-- systems outside the field-audio scope (battle, radio) and stay out of the
-- field-audio semantic API. Any other sound-related reachable opcode fails
-- loudly, naming the opcode and up to three retail callsites. The semantic
-- proof ties raw 726 reachability to emitted process_soundplate resources,
-- walking nested occurrences so no translation gap escapes the corpus count.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")

local T = {}

-- The supported sound-facing field-script commands; all have retail callsites
-- and must be handled by the field-audio runtime. 726 ScrCmd_ProcessSoundplate
-- is the script-facing trigger of the in-scope soundplate system
-- (FieldSystem_ProcessSoundplate(fieldSystem, TRUE)).
local SUPPORTED_OPS = { 73, 74, 75, 78, 79, 80, 81, 82, 84, 85, 87, 726 }
-- Cry/Chatot commands are sound-facing but excluded from completion accounting.
local CRY_OPS = { 76, 77, 89, 90, 91, 92 }
-- Sound-related commands present in source definitions/tables/macros but not at
-- retail field-script callsites; none may enlarge the runtime API.
local ABSENT_OPS = { 83, 86, 88, 93, 544, 575, 664, 665, 666 }
-- Reachable retail opcodes whose owning system is outside the field-audio
-- scope: 218 ScrCmd_EncounterMusic drives battle eyes-meet BGM and 779
-- ScrCmd_RadioMusicIsPlaying is a Pokégear Radio query. They are pinned as
-- observed-reachable yet deliberately outside the field-audio semantic API.
local REACHABLE_EXCLUDED_OPS = { 218, 779 }

-- Every reachable opcode whose catalog name is sound-related (SE/BGM/fanfare/
-- cry/chatot/music/sound) must belong to the declared partition: the name
-- keyword net catches a retail sound command the partition transcript omitted.
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

T["retail sound-opcode census pins the closed partition"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)

  -- Every opcode that has a retail field-script callsite, with provenance.
  local reachable = {}
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for _, script in pairs(ir.scripts) do
        for _, ins in ipairs(script.instructions) do
          local sites = reachable[ins.opcode]
          if sites == nil then
            sites = {}
            reachable[ins.opcode] = sites
          end
          if #sites < 3 then
            sites[#sites + 1] = ("member %d script %d offset 0x%04X"):format(member, script.index, ins.offset)
          end
        end
      end
    end
  end

  -- Every supported command must keep a retail callsite; the supported scope
  -- must never silently shrink.
  local missing = {}
  for _, op in ipairs(SUPPORTED_OPS) do
    if reachable[op] == nil then
      missing[#missing + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#missing, 0, "supported sound opcodes have no retail callsite: " .. table.concat(missing, ", "))

  -- The closed unsupported partition stays unreachable; a divergence fails
  -- loudly with the opcode and its retail callsite provenance.
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

  -- The reachable-but-excluded class is deliberately observed: each entry must
  -- actually keep retail callsites so its exclusion stays an honest, reviewed
  -- scope decision rather than an untested assumption.
  local gone = {}
  for _, op in ipairs(REACHABLE_EXCLUDED_OPS) do
    if reachable[op] == nil then
      gone[#gone + 1] = CommandCatalog.name(op) .. " (" .. tostring(op) .. ")"
    end
  end
  Assert.equal(#gone, 0, "reachable-excluded sound opcodes lost their retail callsites: " .. table.concat(gone, ", "))

  -- No other sound-related reachable opcode may escape the declared partition.
  -- The excluded class is allowed to be reachable; unknown additions are not.
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
end

T["raw 726 reachability survives semantic translation as process_soundplate"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local reachable = 0
  local unsupported726 = 0
  for member = 0, archive:memberCount() - 1 do
    local ir = memberIrs[member]
    if ir ~= nil then
      for _, script in pairs(ir.scripts) do
        for _, ins in ipairs(script.instructions) do
          if ins.opcode == 726 then
            reachable = reachable + 1
          end
        end
      end
    end
  end
  Assert.isTrue(reachable >= 1, "retail corpus must reach opcode 726")
  local semanticCount = 0
  FieldScripts.eachScript(archive, memberIrs, function(_, _, steps, lowered)
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
  end)
  Assert.equal(unsupported726, 0, "no 726 callsite may lower as unsupported")
  Assert.isTrue(semanticCount >= 1, "at least one semantic process_soundplate must originate from 726")
  Assert.equal(semanticCount, reachable, "every raw 726 callsite must survive as a semantic process_soundplate")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
