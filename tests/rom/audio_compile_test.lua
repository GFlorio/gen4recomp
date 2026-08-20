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
-- resulting bundle; playback over these assets is the engine runtime suites'
-- and the acceptance field-music scenarios' contract, not asserted here.
-- The suite also pins the retail corpus facts the runtime contracts rely on:
-- no reachable conditional command, every reachable open_track inside its FE
-- track mask, one active sequence per field player id, the field-script
-- BGM/fanfare/effect player roles never colliding with the BGM players, every
-- emitted op inside the actual runtime playback vocabulary, and the derived
-- sample metadata carrying no source rate or payload path. Counts are derived
-- from the dump, never guessed, and the suite runs for every ready version
-- (soulsilver included when its dump lands).

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioSequence = require("libs.assets.src.AudioSequence")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSample = require("libs.assets.src.AudioSample")
local Sdat = require("romdump.src.digest.audio.Sdat")
local Sseq = require("romdump.src.digest.audio.Sseq")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local Errors = require("libs.errors.src.Errors")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

-- Instruction fields that only make sense while an SSEQ byte stream is being
-- interpreted (source diagnostics live in a separate provenance record,
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

-- The actual runtime playback vocabulary: the ops the player executor
-- handles with real behavior (or nop), mirroring the executor's branches --
-- deliberately not AudioSequence.OPS, so "the validator says it is closed"
-- is never treated as proof the runtime can play it. Comparison ops and
-- conditional instructions are normalized nested operations; the retail
-- corpus gate below proves none reach the current runtime vocabulary.
local SUPPORTED_RUNTIME_OPS = {
  note = true,
  wait = true,
  program = true,
  open_track = true,
  jump = true,
  call = true,
  ["return"] = true,
  setvar = true,
  addvar = true,
  subvar = true,
  mulvar = true,
  divvar = true,
  shiftvar = true,
  randomvar = true,
  pan = true,
  volume = true,
  master_volume = true,
  transpose = true,
  pitch_bend = true,
  pitch_bend_range = true,
  priority = true,
  note_wait = true,
  tie = true,
  portamento_key = true,
  portamento = true,
  portamento_time = true,
  mod_depth = true,
  mod_speed = true,
  mod_type = true,
  mod_range = true,
  mod_delay = true,
  attack = true,
  decay = true,
  sustain = true,
  release = true,
  loop_begin = true,
  loop_end = true,
  expression = true,
  sweep = true,
  mute = true,
  tempo = true,
  ["end"] = true,
  nop = true,
}

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

-- The retail SSEQ census walk: the fixpoint scan over a sequence's raw bytes
-- that the compiler's reachability must stay equivalent to. The walk starts
-- at the data offset, skips the optional FE track-mask header, queues the
-- 0x93/0x94/0x95 branch targets, and stops at a jump/return/end like the
-- lowering walk. Returns the decoded commands in walk order, the FE track
-- mask (nil when absent), and every reachable open_track destination track.
local function censusSequence(bytes, dataOffset)
  local endPos = #bytes
  local pos = dataOffset
  local mask = nil
  if pos < endPos and string.byte(bytes, pos + 1) == 0xFE then
    mask = string.byte(bytes, pos + 2) + string.byte(bytes, pos + 3) * 256
    pos = pos + 3
  end
  local queue = { pos }
  local seen = {}
  local commands = {}
  local openTracks = {}
  while #queue > 0 do
    local start = table.remove(queue)
    if not seen[start] and start < endPos then
      pos = start
      while pos < endPos and not seen[pos] do
        seen[pos] = true
        local command = assert(Sseq.decodeCommand(bytes, pos, endPos, "census"))
        commands[#commands + 1] = command
        pos = command.next
        if command.opcode == 0x93 or command.opcode == 0x94 or command.opcode == 0x95 then
          queue[#queue + 1] = command.target
        end
        if command.opcode == 0x93 then
          openTracks[#openTracks + 1] = command.track
        end
        if command.opcode == 0x94 or command.opcode == 0xFF or command.opcode == 0xFD then
          break
        end
      end
    end
  end
  return commands, mask, openTracks
end

-- Every structured step of every field script of the version context,
-- through the production decoder/lowering/structuring pipeline.
local function eachScriptStep(ctx, fn)
  local archive, memberIrs = FieldScripts.decode(ctx.romFs)
  FieldScripts.eachScript(archive, memberIrs, function(_, _, steps)
    FieldScripts.eachStep(steps, fn)
  end)
end

-- The real archive compiles into the full E1-shaped bundle: every section the
-- writer consumes is present, the marker and dependencies pin the exact ROM
-- and sound archive identity, and the index carries the player and the
-- per-class symbol sections.
function T.compiles_the_real_sound_archive_into_a_complete_bundle()
  forEachVersion(function(ctx)
    local bundle = ctx.bundle
    Assert.equal(type(bundle.marker), "string", "marker is a string")
    Assert.isTrue(bundle.marker:sub(1, #AudioCache.FORMAT) == AudioCache.FORMAT, "marker carries the cache format")
    Assert.isTrue(bundle.marker:find(ctx.metadata.sha1, 1, true) ~= nil, "marker embeds the version rom sha1")
    Assert.equal(bundle.index.schema, AudioCache.INDEX_SCHEMA, "index schema")
    Assert.equal(bundle.index.version, ctx.versionId, "index version")
    for _, section in ipairs({ "sequences", "banks", "players", "sequenceBySymbol", "bankBySymbol" }) do
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
        Assert.equal(entry.bankId, record.bankId, "sequence " .. id .. " index bankId")
        Assert.equal(entry.playerId, record.playerId, "sequence " .. id .. " index playerId")
        local symbol = ctx.sdat.symbols.sequences[id]
        Assert.equal(entry.symbol, symbol, "sequence " .. id .. " index symbol")
        Assert.equal(bundle.index.sequenceBySymbol[symbol], id, "sequence " .. id .. " symbol resolves")

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
        -- Normalized operands live in the op's operand field: amount for the
        -- byte-class commands, duration/program/count for the duration-class
        -- commands. Both normalization shapes (random range, variable) must
        -- occur in the corpus.
        for _, field in ipairs({ "amount", "duration", "program", "count" }) do
          local value = instruction[field]
          if type(value) == "table" then
            if value.kind == "random" then
              randomAmounts = randomAmounts + 1
            elseif value.kind == "variable" then
              variableAmounts = variableAmounts + 1
            end
          end
        end
      end
    end
    Assert.isTrue(instructions >= 1, "the compiled corpus has instructions")
    -- The census guarantees these operations exist in the referenced archive.
    for _, concept in ipairs({
      { name = "note", ops = { "note" } },
      { name = "wait", ops = { "wait" } },
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

-- The emitted IR is behaviorally closed against the actual runtime
-- vocabulary: every op any compiled sequence emits is one the player
-- executor implements with real playback behavior (or nop) -- never an op
-- the runtime would accept without effect, and never a mere known-lowercase
-- name. The executor-side list mirrors its branches, not the validator's
-- table.
function T.every_emitted_op_has_runtime_playback_behavior()
  forEachVersion(function(ctx)
    local emitted = 0
    for id, sequence in pairs(ctx.bundle.sequences) do
      for index, instruction in ipairs(sequence.program.instructions) do
        emitted = emitted + 1
        Assert.isTrue(
          SUPPORTED_RUNTIME_OPS[instruction.op] == true,
          "sequence "
            .. id
            .. " instruction "
            .. index
            .. " emits op "
            .. tostring(instruction.op)
            .. " outside the runtime playback vocabulary"
        )
      end
    end
    Assert.isTrue(emitted >= 1, "the compiled corpus has instructions")
  end)
end

-- Every referenced bank resolves: each used bank slot is indexed under its
-- symbolic name with the archive's wave-archive slot map, and the asset
-- passes the bank validator. Instrument-level wave-archive references are
-- covered by every_referenced_sample_resolves (the compiled banks'
-- sampleKeys must all resolve).
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
        local symbol = ctx.sdat.symbols.banks[id]
        Assert.equal(entry.symbol, symbol, "bank " .. id .. " index symbol")
        Assert.equal(bundle.index.bankBySymbol[symbol], id, "bank " .. id .. " symbol resolves")

        local bank = bundle.banks[id]
        Assert.notNil(bank, "bank " .. id .. " asset present")
        AudioBank.validate(bank)
        Assert.equal(bank.id, id, "bank " .. id .. " asset id")
        Assert.equal(bank.symbol, symbol, "bank " .. id .. " asset symbol")
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
-- content address is the semantic sample identity (decoded PCM, base timer,
-- loop flag, loop window) — not the payload alone — so observably different
-- waves never share a key.
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
      AudioSample.validate(metadata, payload)
      Assert.equal(metadata.key, key, "sample " .. key .. " metadata key")
      Assert.isNil(
        metadata.file,
        "sample " .. key .. " metadata carries no payload path (it derives from the content key)"
      )
      Assert.isNil(
        metadata.sampleRate,
        "sample " .. key .. " metadata carries no source rate (playback comes from the DS timer path)"
      )
      Assert.equal(metadata.frames, math.floor(#payload / 2), "sample " .. key .. " frames match its payload")
      Assert.isTrue(metadata.baseTimer > 0, "sample " .. key .. " carries a valid base timer")
      Assert.equal(
        AudioCompiler.sampleKey(
          payload,
          metadata.baseTimer,
          metadata.loopEnabled,
          metadata.loop.startFrame,
          metadata.loop.endFrame
        ),
        key,
        "sample " .. key .. " content-addressed by its semantic identity"
      )
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
-- compiled sequence through the index's per-class sequence symbol table, so
-- field music can be addressed semantically without raw sequence ids.
function T.all_map_day_night_music_references_resolve()
  forEachVersion(function(ctx)
    local sequenceBySymbol = ctx.bundle.index.sequenceBySymbol
    Assert.equal(type(sequenceBySymbol), "table", "index sequenceBySymbol is a table")
    local maps = 0
    for record in MapCatalog.all() do
      maps = maps + 1
      for _, field in ipairs({ "dayMusic", "nightMusic" }) do
        local id = sequenceBySymbol["SEQ_" .. record[field]]
        Assert.notNil(id, record.symbol .. " " .. field .. " " .. tostring(record[field]) .. " resolves to a sequence")
        Assert.notNil(ctx.bundle.index.sequences[id], record.symbol .. " " .. field .. " sequence compiled")
      end
    end
    Assert.isTrue(maps >= 1, "the map catalog iterated")
  end)
end

-- No reachable SSEQ command in any ready version uses the 0xA2 conditional
-- prefix. The census walks every used sequence's raw bytes with the
-- lowering-identical fixpoint and pins that retail corpus fact; the compiler
-- still preserves conditional commands when a supported source contains one.
function T.no_reachable_conditional_command()
  forEachVersion(function(ctx)
    local conditional = 0
    local checked = 0
    for id = 0, ctx.sdat.counts.sequences - 1 do
      local record = ctx.sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        checked = checked + 1
        local bytes = assert(ctx.sdat:readFile(record.fileId))
        local seq = assert(Sseq.open(bytes, "sequence " .. id))
        local commands = censusSequence(bytes, seq.dataOffset)
        for _, command in ipairs(commands) do
          if command.conditional then
            conditional = conditional + 1
          end
        end
      end
      local sequence = ctx.bundle.sequences[id]
      if sequence ~= nil then
        for _, instruction in ipairs(sequence.program.instructions) do
          Assert.isNil(instruction.conditional, "sequence " .. id .. " emits a conditional instruction")
        end
      end
    end
    Assert.isTrue(checked >= 1, "the census walked used sequences")
    Assert.equal(conditional, 0, "no reachable 0xA2 conditional prefix")
  end)
end

-- Every reachable open_track destination of every retail sequence is
-- allocated by that sequence's FE track mask, and a sequence without an FE
-- header never opens a track. The retail invariant proves that no reachable
-- open_track can fail allocation, so no runtime allocation-failure or
-- global track-pool contention path is ever exercised by the supported
-- corpus.
function T.reachable_open_track_targets_stay_inside_the_fe_mask()
  forEachVersion(function(ctx)
    local checked = 0
    for id = 0, ctx.sdat.counts.sequences - 1 do
      local record = ctx.sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        checked = checked + 1
        local bytes = assert(ctx.sdat:readFile(record.fileId))
        local seq = assert(Sseq.open(bytes, "sequence " .. id))
        local _, mask, openTracks = censusSequence(bytes, seq.dataOffset)
        for _, track in ipairs(openTracks) do
          Assert.notNil(mask, "sequence " .. id .. " opens track " .. track .. " without an FE mask")
          Assert.isTrue(
            math.floor(mask / 2 ^ track) % 2 == 1,
            "sequence "
              .. id
              .. " opens track "
              .. track
              .. " not allocated by its FE mask 0x"
              .. string.format("%04X", mask)
          )
        end
      end
    end
    Assert.isTrue(checked >= 1, "the census walked used sequences")
  end)
end

-- Every player record a used sequence references exists and declares at
-- least one playable sequence; the only player declaring more than one is
-- the intro/PV player (it hosts the opening movie sequences and the
-- end-of-archive sentinels, never field audio). Every player the field
-- flows can reach therefore admits exactly one simultaneous sequence, so
-- one-active-sequence-per-player-id replacement is the supported HGSS
-- behavior and playback identity through the archive player id is
-- unambiguous there.
function T.only_the_intro_player_declares_multiple_sequence_slots()
  forEachVersion(function(ctx)
    local referenced = {}
    for id = 0, ctx.sdat.counts.sequences - 1 do
      local record = ctx.sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        referenced[record.playerId] = true
      end
    end
    Assert.isTrue(next(referenced) ~= nil, "used sequences reference players")
    local multi = {}
    for playerId in pairs(referenced) do
      local player = ctx.sdat.players[playerId]
      Assert.notNil(player, "player " .. playerId .. " referenced by a sequence exists")
      Assert.isTrue(player.maxSequences >= 1, "player " .. playerId .. " declares a usable slot count")
      if player.maxSequences > 1 then
        multi[#multi + 1] = playerId
      end
    end
    table.sort(multi)
    Assert.deepEqual(multi, { 0 }, "only the intro/PV player declares multiple sequence slots")
  end)
end

-- The field-script audio roles of the real archive: every constant
-- BGM/fanfare/effect reference resolves to a compiled sequence, map music
-- always plays on one fixed player id, the fanfare and effect player ids
-- never intersect the BGM player ids (so no fanfare or effect can collide
-- with the active BGM player), and every player a role can reach declares
-- exactly one sequence slot. Fanfares may also be selected dynamically
-- (variable operands), while BGM/effect references are always constants.
-- The BGM role spans two player ids (the field slot and the special
-- scripted-music slot), so replacing the current BGM can switch active
-- player slots and must explicitly stop the previous one.
function T.field_script_audio_roles_never_collide_with_the_bgm_player()
  forEachVersion(function(ctx)
    local bySymbol = ctx.bundle.index.sequenceBySymbol
    local players = {
      bgm = {},
      fanfare = {},
      effect = {},
      waitEffect = {},
    }
    local variableFanfares = 0
    local function resolve(operand)
      local sequenceId = bySymbol[operand]
      Assert.notNil(sequenceId, "script audio reference " .. operand .. " resolves to a compiled sequence")
      return ctx.sdat.sequences[assert(sequenceId)].playerId
    end
    eachScriptStep(ctx, function(step)
      local op = step.op
      if op == "play_music" then
        players.bgm[resolve(step.music)] = true
      elseif op == "play_fanfare" then
        if type(step.fanfare) == "string" then
          players.fanfare[resolve(step.fanfare)] = true
        else
          variableFanfares = variableFanfares + 1
        end
      elseif op == "play_sound" or op == "stop_sound" then
        Assert.isTrue(type(step.sound) == "string", op .. " operands are constants")
        players.effect[resolve(step.sound)] = true
      elseif op == "wait_sound" then
        Assert.isTrue(type(step.sound) == "string", "wait_sound operands are constants")
        players.waitEffect[resolve(step.sound)] = true
      end
    end)
    Assert.isTrue(variableFanfares >= 1, "retail scripts select fanfares dynamically")
    Assert.isTrue(next(players.bgm) ~= nil, "field scripts play BGM")
    Assert.isTrue(next(players.effect) ~= nil, "field scripts play effects")
    local function intersects(a, b)
      for playerId in pairs(a) do
        if b[playerId] then
          return true
        end
      end
      return false
    end
    Assert.isFalse(intersects(players.bgm, players.fanfare), "a fanfare never shares a player id with the BGM players")
    Assert.isFalse(intersects(players.bgm, players.effect), "an effect never shares a player id with the BGM players")
    for playerId in pairs(players.waitEffect) do
      Assert.isTrue(players.effect[playerId] == true, "WaitSE observes only effect players")
    end

    local mapPlayers = {}
    for record in MapCatalog.all() do
      for _, field in ipairs({ "dayMusic", "nightMusic" }) do
        local sequenceId = bySymbol["SEQ_" .. record[field]]
        Assert.notNil(sequenceId, record.symbol .. " " .. field .. " resolves to a compiled sequence")
        mapPlayers[ctx.sdat.sequences[assert(sequenceId)].playerId] = true
      end
    end
    local count = 0
    local only = nil
    for playerId in pairs(mapPlayers) do
      count = count + 1
      only = playerId
    end
    Assert.equal(count, 1, "map music always plays on one fixed player id")
    Assert.isTrue(players.bgm[assert(only)] == true, "the map-music player is a BGM player")

    for role in pairs(players) do
      for playerId in pairs(players[role]) do
        Assert.equal(
          ctx.sdat.players[playerId].maxSequences,
          1,
          role .. " player " .. playerId .. " declares exactly one sequence slot"
        )
      end
    end
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
    every_emitted_op_has_runtime_playback_behavior = T.every_emitted_op_has_runtime_playback_behavior,
    every_referenced_bank_resolves = T.every_referenced_bank_resolves,
    every_referenced_sample_resolves = T.every_referenced_sample_resolves,
    all_map_day_night_music_references_resolve = T.all_map_day_night_music_references_resolve,
    no_reachable_conditional_command = T.no_reachable_conditional_command,
    reachable_open_track_targets_stay_inside_the_fe_mask = T.reachable_open_track_targets_stay_inside_the_fe_mask,
    only_the_intro_player_declares_multiple_sequence_slots = T.only_the_intro_player_declares_multiple_sequence_slots,
    field_script_audio_roles_never_collide_with_the_bgm_player = T.field_script_audio_roles_never_collide_with_the_bgm_player,
  },
}
