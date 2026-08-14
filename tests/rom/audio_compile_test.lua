-- ROM-conformance compilation contract for the real HGSS sound archive: the
-- audio pipeline must compile the entire referenced archive into the frozen
-- derived bundle (marker/index/sequences/banks/samples/sampleMetadata/
-- dependencies) that the cache writer consumes, with every referenced
-- sequence, bank, and sample resolving, no unknown sequence opcode remaining
-- (an unsupported command in a referenced sequence is a build failure, never
-- a placeholder instruction), packed operands normalized, branch targets
-- emitted as instruction indices, and every day/night music reference of the
-- frozen map catalog resolving to a compiled sequence. The expensive compile
-- runs once per ready game version in beforeAll and the scenarios assert the
-- resulting bundle; playback scenarios are not here -- the runtime deliverable
-- that plays these assets does not exist yet. Counts are derived from the
-- dump, never guessed, and the suite runs for every ready version (soulsilver
-- included when its dump lands).

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSample = require("libs.assets.src.AudioSample")
local Sdat = require("romdump.src.digest.audio.Sdat")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local SbnkScan = require("tests.rom.support.SbnkScan")
local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

-- Instruction fields that only make sense while an SSEQ byte stream is being
-- interpreted (spec: source diagnostics live in a separate provenance record,
-- never as behavior-visible instruction fields).
local FORBIDDEN_INSTRUCTION_FIELDS = {
  opcode = true,
  sourceOffset = true,
  sourceOpcode = true,
  sseqOpcode = true,
  sdatInfoOffset = true,
  sbnkRecordType = true,
  swarFileOffset = true,
  swavHeaderBytes = true,
  mode = true,
  varlen = true,
  raw = true,
  operand = true,
}

-- True when a semantic instrument tree contains at least one sample voice.
local function hasSampleVoice(instrument)
  local function visit(voice)
    return type(voice.generator) == "table" and voice.generator.kind == "sample"
  end
  if instrument.kind == "direct" then
    return visit(instrument.voice)
  end
  if instrument.kind == "key_split" then
    for _, range in ipairs(instrument.ranges) do
      if visit(range.voice) then
        return true
      end
    end
    return false
  end
  if instrument.kind == "drum_set" then
    for _, voice in ipairs(instrument.voices) do
      if visit(voice) then
        return true
      end
    end
  end
  return false
end

local T = {}
local contexts = nil

function T.beforeAll()
  local opened = {}
  contexts = opened
  local readyVersions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyVersions[#readyVersions + 1] = versionId
    end
  end
  for _, versionId in ipairs(readyVersions) do
    local entry = { versionId = versionId, romFs = assert(RomFs.open(versionId)) }
    opened[#opened + 1] = entry
    local ok, err = pcall(function()
      entry.sdatBytes = assert(entry.romFs:readSourcePath(SDAT_PATH), "cannot read " .. SDAT_PATH)
      entry.sdat = assert(Sdat.open(entry.sdatBytes, SDAT_PATH), "cannot parse " .. SDAT_PATH)
      entry.metadata = entry.romFs:metadata()
      local bundle, compileErr = AudioCompiler.compile(entry.romFs)
      Assert.notNil(bundle, "compile failed: " .. (compileErr and Errors.format(compileErr) or "no error"))
      entry.bundle = assert(bundle)
    end)
    if not ok then
      error(versionId .. ": " .. tostring(err), 0)
    end
  end
end

function T.afterAll()
  local opened = contexts
  contexts = nil
  if opened ~= nil then
    for _, entry in ipairs(opened) do
      entry.romFs:close()
    end
  end
end

local function forEachVersion(fn)
  for _, ctx in ipairs(assert(contexts, "the audio compile suite has no open contexts")) do
    local ok, err = pcall(fn, ctx)
    if not ok then
      error(ctx.versionId .. ": " .. tostring(err), 0)
    end
  end
end

-- The real archive compiles into the full E1-shaped bundle: every section the
-- writer consumes is present, the marker and dependencies pin the exact ROM
-- and sound archive identity, and the index carries the player and bySymbol
-- sections.
function T.compiles_the_real_sound_archive_into_a_complete_bundle()
  forEachVersion(function(ctx)
    local bundle = ctx.bundle
    Assert.equal(type(bundle.marker), "string", "marker is a string")
    Assert.isTrue(bundle.marker:sub(1, #AudioCache.FORMAT) == AudioCache.FORMAT, "marker carries the cache format")
    Assert.isTrue(bundle.marker:find(ctx.metadata.sha1, 1, true) ~= nil, "marker embeds the version rom sha1")
    Assert.equal(bundle.index.schema, AudioCache.INDEX_SCHEMA, "index schema")
    Assert.equal(bundle.index.version, ctx.versionId, "index version")
    for _, section in ipairs({ "sequences", "banks", "players", "bySymbol" }) do
      Assert.equal(type(bundle.index[section]), "table", "index." .. section .. " is a table")
    end
    for _, section in ipairs({ "sequences", "banks", "samples", "sampleMetadata" }) do
      Assert.equal(type(bundle[section]), "table", "bundle." .. section .. " is a table")
    end
    Assert.equal(type(bundle.dependencies), "table", "dependencies is a table")
    Assert.equal(bundle.dependencies.cacheFormat, AudioCache.FORMAT, "dependencies.cacheFormat")
    Assert.equal(bundle.dependencies.versionRomSha1, ctx.metadata.sha1, "dependencies.versionRomSha1")
    local archive = bundle.dependencies.soundArchive
    Assert.equal(type(archive), "table", "dependencies.soundArchive is a table")
    Assert.equal(archive.path, SDAT_PATH, "soundArchive.path")
    Assert.equal(archive.fileId, ctx.romFs:fileIdForPath(SDAT_PATH), "soundArchive.fileId")
    Assert.equal(archive.sha1, Hashing.sha1hex(ctx.sdatBytes), "soundArchive.sha1")

    local indexedPlayers = 0
    for id = 0, ctx.sdat.counts.players - 1 do
      local record = ctx.sdat.players[id]
      if record ~= nil then
        indexedPlayers = indexedPlayers + 1
        local entry = bundle.index.players[id]
        Assert.notNil(entry, "player " .. id .. " indexed")
        Assert.equal(entry.id, id, "player " .. id .. " index id")
        Assert.equal(entry.maxSequences, record.maxSequences, "player " .. id .. " maxSequences")
        Assert.equal(entry.channelMask, record.channelMask, "player " .. id .. " channelMask")
        Assert.equal(entry.heapSize, record.heapSize, "player " .. id .. " heapSize")
      end
    end
    Assert.isTrue(indexedPlayers >= 1, "at least one player indexed")
  end)
end

-- Every referenced sequence compiles: each used INFO slot is indexed with its
-- symbolic name and bank/player references, the asset carries the same
-- identity and the archive's player parameters, passes the sequence validator,
-- and its bank id resolves.
function T.every_referenced_sequence_compiles()
  forEachVersion(function(ctx)
    local bundle = ctx.bundle
    local compiled = 0
    for id = 0, ctx.sdat.counts.sequences - 1 do
      local record = ctx.sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        compiled = compiled + 1
        local entry = bundle.index.sequences[id]
        Assert.notNil(entry, "sequence " .. id .. " indexed")
        Assert.equal(entry.id, id, "sequence " .. id .. " index id")
        Assert.equal(entry.file, AudioCache.sequencePath(id), "sequence " .. id .. " index file")
        Assert.equal(entry.bankId, record.bankId, "sequence " .. id .. " index bankId")
        Assert.equal(entry.playerId, record.playerId, "sequence " .. id .. " index playerId")
        local symbol = ctx.sdat.symbols.sequences[id]
        Assert.equal(entry.symbol, symbol, "sequence " .. id .. " index symbol")
        Assert.equal(bundle.index.bySymbol[symbol], id, "sequence " .. id .. " bySymbol resolves")

        local sequence = bundle.sequences[id]
        Assert.notNil(sequence, "sequence " .. id .. " asset present")
        AudioSequence.validate(sequence)
        Assert.equal(sequence.id, id, "sequence " .. id .. " asset id")
        Assert.equal(sequence.symbol, symbol, "sequence " .. id .. " asset symbol")
        Assert.equal(sequence.bankId, record.bankId, "sequence " .. id .. " asset bankId")
        if sequence.bankId ~= 0xFFFF then
          Assert.notNil(bundle.index.banks[sequence.bankId], "sequence " .. id .. " bankId resolves")
        end
        Assert.equal(sequence.player.id, record.playerId, "sequence " .. id .. " player id")
        Assert.equal(sequence.player.initialVolume, record.volume, "sequence " .. id .. " initialVolume")
        Assert.equal(sequence.player.channelPriority, record.channelPriority, "sequence " .. id .. " channelPriority")
        Assert.equal(sequence.player.playerPriority, record.playerPriority, "sequence " .. id .. " playerPriority")
      end
    end
    for id in pairs(bundle.index.sequences) do
      local record = ctx.sdat.sequences[id]
      Assert.isTrue(record ~= nil and record.fileId ~= nil, "index sequence " .. id .. " is a used INFO slot")
    end
    Assert.isTrue(compiled >= 1, "at least one sequence compiled")
  end)
end

-- No unknown sequence opcode remains: every instruction carries a semantic
-- lowercase operation name (never a raw opcode, an offset, or an
-- unsupported placeholder), branch targets are instruction indices, the
-- census-mandated core operations all appear, and both packed-operand
-- normalization shapes (random range, variable) occur in the corpus.
function T.no_unknown_sequence_opcode_remains()
  forEachVersion(function(ctx)
    local seen = {}
    local randomAmounts, variableAmounts = 0, 0
    local instructions = 0
    for id, sequence in pairs(ctx.bundle.sequences) do
      for index, instruction in ipairs(sequence.program.instructions) do
        instructions = instructions + 1
        local op = instruction.op
        Assert.equal(type(op), "string", "sequence " .. id .. " instruction " .. index .. " has an op")
        Assert.isTrue(
          op:match("^[a-z][a-z0-9_]*$") ~= nil,
          "sequence " .. id .. " op " .. tostring(op) .. " is a semantic name"
        )
        Assert.isTrue(
          op ~= "unsupported" and op ~= "unknown",
          "sequence " .. id .. " never emits an unsupported placeholder op"
        )
        for field in pairs(instruction) do
          Assert.isFalse(
            FORBIDDEN_INSTRUCTION_FIELDS[field] == true,
            "sequence " .. id .. " instruction " .. index .. " leaks source field " .. tostring(field)
          )
        end
        seen[op] = true
        local amount = instruction.amount
        if type(amount) == "table" then
          if amount.kind == "random" then
            randomAmounts = randomAmounts + 1
          elseif amount.kind == "variable" then
            variableAmounts = variableAmounts + 1
          end
        end
      end
    end
    Assert.isTrue(instructions >= 1, "the compiled corpus has instructions")
    -- The census guarantees these operations exist in the referenced archive.
    for _, concept in ipairs({
      { name = "note", ops = { "note" } },
      { name = "wait/rest", ops = { "wait", "rest" } },
      { name = "program", ops = { "program" } },
      { name = "jump", ops = { "jump" } },
      { name = "call", ops = { "call" } },
      { name = "return", ops = { "return" } },
      { name = "tempo", ops = { "tempo" } },
      { name = "pan", ops = { "pan" } },
      { name = "volume", ops = { "volume" } },
      { name = "open_track", ops = { "open_track" } },
    }) do
      local found = false
      for _, op in ipairs(concept.ops) do
        if seen[op] then
          found = true
        end
      end
      Assert.isTrue(found, "corpus contains " .. concept.name)
    end
    Assert.isTrue(randomAmounts >= 1, "random operands normalize to {kind=random}")
    Assert.isTrue(variableAmounts >= 1, "variable operands normalize to {kind=variable}")
  end)
end

-- Every referenced bank resolves: each used bank slot is indexed under its
-- symbolic name with the archive's wave-archive slot map, the asset passes
-- the bank validator, and every instrument the source walk finds as
-- wave-referencing is present as a semantic instrument holding a sample
-- voice.
function T.every_referenced_bank_resolves()
  forEachVersion(function(ctx)
    local bundle = ctx.bundle
    local compiled = 0
    for id = 0, ctx.sdat.counts.banks - 1 do
      local record = ctx.sdat.banks[id]
      if record ~= nil and record.fileId ~= nil then
        compiled = compiled + 1
        local entry = bundle.index.banks[id]
        Assert.notNil(entry, "bank " .. id .. " indexed")
        Assert.equal(entry.id, id, "bank " .. id .. " index id")
        Assert.equal(entry.file, AudioCache.bankPath(id), "bank " .. id .. " index file")
        local symbol = ctx.sdat.symbols.banks[id]
        Assert.equal(entry.symbol, symbol, "bank " .. id .. " index symbol")
        Assert.equal(bundle.index.bySymbol[symbol], id, "bank " .. id .. " bySymbol resolves")

        local bank = bundle.banks[id]
        Assert.notNil(bank, "bank " .. id .. " asset present")
        AudioBank.validate(bank)
        Assert.equal(bank.id, id, "bank " .. id .. " asset id")
        Assert.equal(bank.symbol, symbol, "bank " .. id .. " asset symbol")
        if next(record.waveArchives) ~= nil then
          Assert.deepEqual(bank.waveArchives, record.waveArchives, "bank " .. id .. " waveArchives")
        else
          Assert.isTrue(
            bank.waveArchives == nil or next(bank.waveArchives) == nil,
            "bank " .. id .. " waveArchives empty"
          )
        end

        local bankBytes = assert(ctx.sdat:readFile(record.fileId), "bank " .. id .. " readable")
        local scan = SbnkScan.scan(bankBytes)
        Assert.equal(#scan.anomalies, 0, "bank " .. id .. " source instrument walk bounded")
        local sampleRecords = {}
        for _, inst in ipairs(scan.instruments) do
          if inst.swarSlot ~= nil then
            sampleRecords[inst.index] = true
          end
        end
        for index in pairs(sampleRecords) do
          local instrument = bank.instruments[index]
          Assert.notNil(instrument, "bank " .. id .. " instrument " .. index .. " present")
          Assert.isTrue(hasSampleVoice(instrument), "bank " .. id .. " instrument " .. index .. " has a sample voice")
        end
      end
    end
    for id in pairs(bundle.index.banks) do
      local record = ctx.sdat.banks[id]
      Assert.isTrue(record ~= nil and record.fileId ~= nil, "index bank " .. id .. " is a used INFO slot")
    end
    Assert.isTrue(compiled >= 1, "at least one bank compiled")
  end)
end

-- Every referenced sample resolves: every sample key any bank voice references
-- has its metadata and PCM payload, every payload is even-length signed PCM16
-- whose frame count matches its metadata, every loop window is valid, and the
-- content address is the payload's own sha1, so equal waves share one key.
function T.every_referenced_sample_resolves()
  forEachVersion(function(ctx)
    local bundle = ctx.bundle
    local referenced = {}
    for id, bank in pairs(bundle.banks) do
      local keys = AudioBank.sampleKeys(bank)
      Assert.notNil(keys, "bank " .. tostring(id) .. " sample references readable")
      keys = assert(keys)
      for _, key in ipairs(keys) do
        referenced[key] = true
      end
    end
    Assert.isTrue(next(referenced) ~= nil, "the compiled banks reference samples")

    local emitted = 0
    for key, payload in pairs(bundle.samples) do
      emitted = emitted + 1
      Assert.equal(type(payload), "string", "sample " .. key .. " payload is bytes")
      Assert.isTrue(#payload >= 2 and #payload % 2 == 0, "sample " .. key .. " payload is even non-empty PCM16")
      local metadata = bundle.sampleMetadata[key]
      Assert.notNil(metadata, "sample " .. key .. " metadata present")
      AudioSample.validate(metadata)
      Assert.equal(metadata.key, key, "sample " .. key .. " metadata key")
      Assert.equal(metadata.file, AudioCache.samplePath(key), "sample " .. key .. " metadata file")
      Assert.equal(metadata.frames, math.floor(#payload / 2), "sample " .. key .. " frames match its payload")
      Assert.equal(Hashing.sha1hex(payload), key, "sample " .. key .. " content-addressed by its payload")
    end
    for key in pairs(bundle.sampleMetadata) do
      Assert.notNil(bundle.samples[key], "sample " .. key .. " metadata without payload")
    end
    local referencedCount = 0
    for key in pairs(referenced) do
      referencedCount = referencedCount + 1
      Assert.notNil(bundle.samples[key], "referenced sample " .. key .. " payload present")
      Assert.notNil(bundle.sampleMetadata[key], "referenced sample " .. key .. " metadata present")
    end
    Assert.isTrue(referencedCount >= 1, "at least one referenced sample")
    Assert.isTrue(emitted >= 1, "at least one sample emitted")
  end)
end

-- Every day/night music reference of the frozen map catalog resolves to a
-- compiled sequence through the index's symbol table, so field music can be
-- addressed semantically without raw sequence ids.
function T.all_map_day_night_music_references_resolve()
  forEachVersion(function(ctx)
    local bySymbol = ctx.bundle.index.bySymbol
    Assert.equal(type(bySymbol), "table", "index bySymbol is a table")
    local maps = 0
    for record in MapCatalog.all() do
      maps = maps + 1
      for _, field in ipairs({ "dayMusic", "nightMusic" }) do
        local id = bySymbol["SEQ_" .. record[field]]
        Assert.notNil(id, record.symbol .. " " .. field .. " " .. tostring(record[field]) .. " resolves to a sequence")
        Assert.notNil(ctx.bundle.index.sequences[id], record.symbol .. " " .. field .. " sequence compiled")
      end
    end
    Assert.isTrue(maps >= 1, "the map catalog iterated")
  end)
end

return {
  metadata = { capabilities = { "rom_dump" } },
  beforeAll = T.beforeAll,
  afterAll = T.afterAll,
  tests = {
    compiles_the_real_sound_archive_into_a_complete_bundle = T.compiles_the_real_sound_archive_into_a_complete_bundle,
    every_referenced_sequence_compiles = T.every_referenced_sequence_compiles,
    no_unknown_sequence_opcode_remains = T.no_unknown_sequence_opcode_remains,
    every_referenced_bank_resolves = T.every_referenced_bank_resolves,
    every_referenced_sample_resolves = T.every_referenced_sample_resolves,
    all_map_day_night_music_references_resolve = T.all_map_day_night_music_references_resolve,
  },
}
