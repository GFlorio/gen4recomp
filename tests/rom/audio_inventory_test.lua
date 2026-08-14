-- ROM-conformance inventory of the real HGSS sound archive: the SDAT must
-- parse, every referenced resource must carry its class
-- signature at a declared size matching its FAT range, every sequence->bank
-- and bank->wave-archive reference must resolve, the symbol block must cover
-- every used slot, and every reachable SSEQ instruction must be enumerable
-- with a known operand shape under the NitroSDK command layout -- no unbounded
-- reads, no target outside the walked program. The inventory asserts
-- self-consistency and determinism, never guessed expected counts, and runs
-- for every ready game version (soulsilver included when its dump lands).
--
-- The SSEQ/SBNK walking lives in tests/rom/support fixtures (SseqScan,
-- SbnkScan) until the production decoders land in later audio work; the SDAT
-- container parsing is production code (romdump/src/digest/audio/Sdat.lua).

local Assert = require("tests.support.Assert")
local Sdat = require("romdump.src.digest.audio.Sdat")
local SseqScan = require("tests.rom.support.SseqScan")
local SbnkScan = require("tests.rom.support.SbnkScan")

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
function T.parses_and_reports_consistent_counts(romFs, version)
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
function T.sequence_to_bank_references_resolve(romFs, version)
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
-- slot of a bank record names a used wave archive, and every instrument in
-- the bank payload references a slot the bank record actually assigns.
function T.bank_to_wave_archive_references_resolve(romFs, version)
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

    local bankBytes = assert(sdat:readFile(bank.fileId), "bank " .. id .. " readable")
    local scan = SbnkScan.scan(bankBytes)
    Assert.equal(
      #scan.anomalies,
      0,
      "bank " .. id .. " instrument walk bounded, got " .. tostring(scan.anomalies[1] and scan.anomalies[1].kind)
    )
    for _, inst in ipairs(scan.instruments) do
      local swarSlot = inst.swarSlot
      if swarSlot ~= nil then
        Assert.isTrue(swarSlot >= 0 and swarSlot <= 3, "bank " .. id .. " instrument slot in 0..3")
        Assert.notNil(slots[swarSlot], "bank " .. id .. " instrument references assigned slot " .. swarSlot)
      end
    end
  end
end

-- The symbol block exists and names every used slot of every section.
function T.symbol_block_covers_every_used_slot(romFs, version)
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

-- Every SSEQ in the archive scans with a bounded, SDK-shaped instruction
-- walk: no anomalies, every jump/call target inside the file and on an
-- instruction boundary, the full reachable opcode vocabulary (including
-- operand variants) enumerated, and the census identical across two scans.
function T.sseq_opcode_inventory_is_complete_and_deterministic(romFs, version)
  local sdat = parseSdat(romFs)
  local aggregate = {}
  local scanned = 0
  local firstScan
  local firstUsedId

  for _, id in ipairs(usedIds(sdat.sequences, sdat.counts.sequences)) do
    local seq = sdat.sequences[id]
    local bytes = assert(sdat:readFile(seq.fileId), "sequence " .. id .. " readable")
    Assert.equal(bytes:sub(1, 4), "SSEQ", "sequence " .. id .. " is SSEQ")
    local scan = SseqScan.scan(bytes)
    Assert.equal(
      #scan.anomalies,
      0,
      "sequence " .. id .. " bounded scan, got " .. tostring(scan.anomalies[1] and scan.anomalies[1].kind)
    )
    for _, tgt in ipairs(scan.targets) do
      Assert.isTrue(tgt.target < #bytes, "sequence " .. id .. " target inside file")
      Assert.isTrue(scan.boundaries[tgt.target], "sequence " .. id .. " target on instruction boundary")
    end
    for key, count in pairs(scan.census) do
      aggregate[key] = (aggregate[key] or 0) + count
    end
    if firstScan == nil then
      firstScan = scan
      firstUsedId = id
    end
    scanned = scanned + 1
  end
  Assert.isTrue(scanned >= 1, "at least one sequence scanned")

  -- Determinism: rescanning the same file yields the identical census.
  local secondScan = SseqScan.scan(assert(sdat:readFile(sdat.sequences[firstUsedId].fileId)))
  Assert.deepEqual(secondScan.census, firstScan.census)

  -- Core vocabulary every music SSEQ set must contain (presence, not counts).
  for _, key in ipairs({
    "80:plain",
    "81:plain",
    "93:plain",
    "94:plain",
    "95:plain",
    "E1:plain",
    "C1:plain",
    "FF:plain",
  }) do
    Assert.isTrue((aggregate[key] or 0) > 0, "opcode " .. key .. " encountered")
  end
  -- Notes: at least one key in 0x00-0x7F.
  local anyNote = false
  for key in pairs(aggregate) do
    local opcode = tonumber(key:sub(1, 2), 16)
    if opcode ~= nil and opcode < 0x80 then
      anyNote = true
    end
  end
  Assert.isTrue(anyNote, "note commands encountered")
  -- The random/variable/if prefixes never appear as bare commands.
  for _, prefix in ipairs({ "A0", "A1", "A2" }) do
    Assert.isNil(aggregate[prefix .. ":plain"], "prefix " .. prefix .. " only ever prefixes")
  end
end

-- Parsing the archive twice yields identical counts, records, and symbols.
function T.parsing_is_deterministic(romFs, version)
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
