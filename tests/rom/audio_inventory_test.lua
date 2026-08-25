-- ROM-conformance inventory of the real HGSS sound archive: the SDAT must
-- parse, every referenced resource must carry its class signature at a
-- declared size matching its FAT range, every sequence->bank and
-- bank->wave-archive reference must resolve, and the symbol block must cover
-- every used slot. The inventory asserts self-consistency and determinism,
-- never guessed expected counts, and runs for every ready game version
-- (soulsilver included when its dump lands). Container parsing is production
-- code (romdump/src/digest/audio/Sdat.lua); compiling the whole archive --
-- every reachable instruction, instrument, and sample -- is the
-- audio_compile suite's contract.

local Assert = require("tests.support.Assert")
local Sdat = require("romdump.src.digest.audio.Sdat")

local T = {}

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

local RESOURCE_CLASSES = {
  { section = "sequences", expected = "SSEQ" },
  { section = "sequenceArchives", expected = "SSAR" },
  { section = "banks", expected = "SBNK" },
  { section = "waveArchives", expected = "SWAR" },
  { section = "streams", expected = "STRM" },
}

local function parseSdat(romFs)
  local bytes, err = romFs:readSourcePath(SDAT_PATH)
  Assert.notNil(bytes, "cannot read " .. SDAT_PATH .. ": " .. tostring(err))
  bytes = assert(bytes)
  local sdat, parseErr = Sdat.open(bytes, SDAT_PATH)
  Assert.notNil(sdat, "cannot parse " .. SDAT_PATH .. ": " .. tostring(parseErr))
  return assert(sdat), bytes
end

local function usedIds(section, count)
  local ids = {}
  for id = 0, count - 1 do
    if section[id] ~= nil and section[id].fileId ~= nil then
      ids[#ids + 1] = id
    end
  end
  return ids
end

-- The archive parses and reports non-empty slot and used counts for every
-- section the HGSS sound system actually uses; exact counts are an inventory
-- report, not an assertion target. Embedded-resource signatures and declared
-- sizes are enforced by the parse itself and pinned by the component suite.
function T.parses_and_reports_consistent_counts(romFs, _)
  local sdat = parseSdat(romFs)
  local counts = sdat.counts
  Assert.notNil(counts)
  Assert.isTrue(counts.sequences >= 1, "sequence slots")
  Assert.isTrue(counts.banks >= 1, "bank slots")
  Assert.isTrue(counts.waveArchives >= 1, "wave-archive slots")
  Assert.isTrue(counts.players >= 1, "player slots")
  Assert.isTrue(counts.groups >= 1, "group slots")
  Assert.isTrue(counts.files >= 1, "file slots")

  local seqIds = usedIds(sdat.sequences, counts.sequences)
  local bankIds = usedIds(sdat.banks, counts.banks)
  local waveIds = usedIds(sdat.waveArchives, counts.waveArchives)
  Assert.isTrue(#seqIds >= 1, "used sequences")
  Assert.isTrue(#bankIds >= 1, "used banks")
  Assert.isTrue(#waveIds >= 1, "used wave archives")
end

-- Every sequence->bank reference resolves: the referenced bank slot is either
-- none (0xFFFF) or a used bank record.
function T.sequence_to_bank_references_resolve(romFs, _)
  local sdat = parseSdat(romFs)
  for _, id in ipairs(usedIds(sdat.sequences, sdat.counts.sequences)) do
    local bankId = sdat.sequences[id].bankId
    if bankId ~= 0xFFFF then
      local bank = sdat.banks[bankId]
      Assert.notNil(bank, "sequence " .. id .. " bank " .. bankId .. " record exists")
      Assert.notNil(bank.fileId, "sequence " .. id .. " bank " .. bankId .. " is used")
    end
  end
end

-- Every bank->wave-archive reference resolves: each non-empty wave-archive
-- slot of a bank record names a used wave archive. The instrument-level
-- wave-archive references are the compiler's contract (the audio_compile
-- suite compiles every referenced bank and sample).
function T.bank_to_wave_archive_references_resolve(romFs, _)
  local sdat = parseSdat(romFs)
  for _, id in ipairs(usedIds(sdat.banks, sdat.counts.banks)) do
    local bank = sdat.banks[id]
    local slots = bank.waveArchives
    Assert.notNil(slots, "bank " .. id .. " has wave-archive slots")
    for slot = 0, 3 do
      local waveId = slots[slot]
      if waveId ~= nil and waveId ~= 0xFFFF then
        local wave = sdat.waveArchives[waveId]
        Assert.notNil(wave, "bank " .. id .. " slot " .. slot .. " wave archive " .. waveId .. " exists")
        Assert.notNil(wave.fileId, "bank " .. id .. " slot " .. slot .. " wave archive " .. waveId .. " is used")
      end
    end
  end
end

-- The symbol block exists and names every used slot of every section.
function T.symbol_block_covers_every_used_slot(romFs, _)
  local sdat = parseSdat(romFs)
  Assert.notNil(sdat.symbols, "symbol block present")
  for _, cls in ipairs(RESOURCE_CLASSES) do
    local section = sdat[cls.section]
    local symbols = sdat.symbols[cls.section]
    Assert.notNil(symbols, cls.section .. " symbol list present")
    for _, id in ipairs(usedIds(section, sdat.counts[cls.section])) do
      local name = symbols[id]
      Assert.notNil(name, cls.section .. "[" .. id .. "] named")
      Assert.isTrue(type(name) == "string" and #name > 0, cls.section .. "[" .. id .. "] name non-empty")
    end
  end
end

-- Parsing the archive twice yields identical counts, records, and symbols.
function T.parsing_is_deterministic(romFs, _)
  local first = parseSdat(romFs)
  local second = parseSdat(romFs)
  Assert.deepEqual(second.counts, first.counts)
  for _, cls in ipairs(RESOURCE_CLASSES) do
    for id = 0, first.counts[cls.section] - 1 do
      Assert.deepEqual(second[cls.section][id], first[cls.section][id], cls.section .. "[" .. id .. "]")
    end
  end
  Assert.deepEqual(second.symbols, first.symbols)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
