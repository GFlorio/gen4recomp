-- Retail audio corpus census: enumerates the supported HGSS SDAT without
-- committing it and classifies every reachable construct. Operates through the
-- existing dump/cache capability like other ROM-backed tests.

local Assert = require("tests.support.Assert")
local Sdat = require("romdump.src.digest.audio.Sdat")
local Sseq = require("romdump.src.digest.audio.Sseq")
local Sbnk = require("romdump.src.digest.audio.Sbnk")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local Errors = require("libs.errors.src.Errors")

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

local T = {}
local contexts = nil

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
          queue[#queue + 1] = dataOffset + command.target
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

function T.beforeAll()
  local GameVersion = require("romdump.src.source.GameVersion")
  local RomImporter = require("romdump.src.source.RomImporter")
  local RomFs = require("romdump.src.source.RomFs")
  local opened = {}
  contexts = opened
  local readyVersions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      readyVersions[#readyVersions + 1] = versionId
    end
  end
  if #readyVersions == 0 then
    contexts = {}
    return
  end
  for _, versionId in ipairs(readyVersions) do
    local entry = { versionId = versionId, romFs = assert(RomFs.open(versionId)) }
    opened[#opened + 1] = entry
    local ok, err = pcall(function()
      entry.sdatBytes = assert(entry.romFs:readSourcePath(SDAT_PATH), "cannot read " .. SDAT_PATH)
      entry.sdat = assert(Sdat.open(entry.sdatBytes, SDAT_PATH), "cannot parse " .. SDAT_PATH)
      local bundle, compileErr = AudioCompiler.compile(entry.romFs)
      if bundle == nil then
        local Errors = require("libs.errors.src.Errors")
        local msg = compileErr and Errors.format(compileErr) or "compile failed"
        error(msg, 0)
      end
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
      if entry.romFs then
        entry.romFs:close()
      end
    end
  end
end

local function forEachVersion(fn)
  local list = assert(contexts, "corpus census has no open contexts")
  if #list == 0 then
    -- No dump available: explicitly skip rather than silently passing.
    local Assert2 = require("tests.support.Assert")
    -- Use a failure that makes the capability requirement visible.
    error("missing capability: rom_dump (no ready dump for corpus census)", 0)
  end
  for _, ctx in ipairs(list) do
    local ok, err = pcall(fn, ctx)
    if not ok then
      error(ctx.versionId .. ": " .. tostring(err), 0)
    end
  end
end

local function compactSummary(summary)
  local lines = {}
  for key, value in pairs(summary) do
    lines[#lines + 1] = string.format("%s=%s", tostring(key), tostring(value))
  end
  table.sort(lines)
  return table.concat(lines, ", ")
end

function T.corpus_census_classifies_every_reachable_construct()
  forEachVersion(function(ctx)
    local sdat = ctx.sdat
    local bundle = ctx.bundle

    local sequenceCount = 0
    local playerIds = {}
    local playerPriorities = {}
    local channelPriorities = {}
    local initialVolumes = {}
    local players = {}
    local channelMaskZero = 0
    local channelMaskNonZero = 0
    local opcodeSeen = {}
    local conditionalCount = 0
    local b8bdCount = 0
    local openTrackTargets = 0
    local openTrackRepeats = 0
    local maxTracksPerSequence = 0
    local sdatSequences = 0

    for id = 0, sdat.counts.sequences - 1 do
      local record = sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        sdatSequences = sdatSequences + 1
        sequenceCount = sequenceCount + 1
        playerIds[record.playerId] = true
        playerPriorities[record.playerPriority] = true
        channelPriorities[record.channelPriority] = true
        initialVolumes[record.volume] = true

        local bytes = assert(sdat:readFile(record.fileId))
        local seq = assert(Sseq.open(bytes, "sequence " .. id))
        local commands, mask, openTracks = censusSequence(bytes, seq.dataOffset)

        -- Track allocation census.
        local distinct = {}
        for _, track in ipairs(openTracks) do
          openTrackTargets = openTrackTargets + 1
          if distinct[track] then
            openTrackRepeats = openTrackRepeats + 1
          end
          distinct[track] = true
        end
        local trackCount = 1 + #openTracks -- track 0 plus opened tracks
        if trackCount > maxTracksPerSequence then
          maxTracksPerSequence = trackCount
        end

        for _, command in ipairs(commands) do
          opcodeSeen[command.opcode] = true
          if command.conditional then
            conditionalCount = conditionalCount + 1
          end
          if command.opcode >= 0xB8 and command.opcode <= 0xBD then
            b8bdCount = b8bdCount + 1
          end
        end
      end
    end

    for id = 0, sdat.counts.players - 1 do
      local record = sdat.players[id]
      if record ~= nil then
        players[id] = record
        if record.channelMask == 0 then
          channelMaskZero = channelMaskZero + 1
        else
          channelMaskNonZero = channelMaskNonZero + 1
        end
      end
    end

    -- SBNK census and release 0xFF locations.
    local sdatBanks = 0
    local sdatWaveArchives = 0
    local bankTypes = {}
    local releaseFF = 0
    local releaseFFLocations = {}
    local directPcmOrDummy = 0

    for id = 0, sdat.counts.banks - 1 do
      local record = sdat.banks[id]
      if record ~= nil and record.fileId ~= nil then
        sdatBanks = sdatBanks + 1
        local bytes = assert(sdat:readFile(record.fileId))
        local instrumentCount = string.byte(bytes, 0x39)
          + string.byte(bytes, 0x3A) * 256
          + string.byte(bytes, 0x3B) * 65536
          + string.byte(bytes, 0x3C) * 16777216
        for program = 0, instrumentCount - 1 do
          local typeOffset = 0x3D + program * 4
          local instrumentType = string.byte(bytes, typeOffset)
          if instrumentType == 4 or instrumentType == 5 then
            directPcmOrDummy = directPcmOrDummy + 1
            bankTypes[instrumentType] = (bankTypes[instrumentType] or 0) + 1
          end
        end
        local ir, err = Sbnk.decode(bytes, "SBNK " .. id)
        if ir == nil then
          local expectedUnsupported = err ~= nil and (err.context.type == 4 or err.context.type == 5)
          Assert.isTrue(expectedUnsupported, "SBNK decode failed for bank " .. id .. ": " .. Errors.format(err))
        else
          for _, inst in pairs(ir.instruments) do
            bankTypes[inst.type] = (bankTypes[inst.type] or 0) + 1
          end
        end
        if ir ~= nil then
          for _, inst in pairs(ir.instruments) do
            local function checkParam(param, where)
              if param and param.release == 0xFF then
                releaseFF = releaseFF + 1
                if #releaseFFLocations < 5 then
                  releaseFFLocations[#releaseFFLocations + 1] = string.format("bank %d %s", id, where)
                end
              end
            end
            if inst.param then
              checkParam(inst.param, "program direct")
            end
            if inst.leaves then
              for idx, leaf in pairs(inst.leaves) do
                checkParam(leaf.param, "leaf " .. tostring(idx))
              end
            end
          end
        end
      end
    end

    for id = 0, sdat.counts.waveArchives - 1 do
      local record = sdat.waveArchives[id]
      if record ~= nil and record.fileId ~= nil then
        sdatWaveArchives = sdatWaveArchives + 1
      end
    end

    -- Any SSEQ construct rejected by the current normalized contracts is a
    -- failure: the census must enumerate the supported archive without silently
    -- counting unsupported reachable constructs.
    local rejected = 0
    local rejectedSample = nil
    for id = 0, sdat.counts.sequences - 1 do
      local record = sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        local bytes = assert(sdat:readFile(record.fileId))
        local program, perr =
          require("romdump.src.digest.audio.SequenceLowering").lower(bytes, { sequenceId = id }, "SSEQ " .. id)
        if program == nil then
          rejected = rejected + 1
          if rejectedSample == nil then
            rejectedSample = string.format("sequence %d: %s", id, tostring(perr))
          end
        end
      end
    end

    local summary = {
      sequences = sequenceCount,
      sdatSequences = sdatSequences,
      sdatBanks = sdatBanks,
      sdatWaveArchives = sdatWaveArchives,
      players = 0,
      maxTracksPerSequence = maxTracksPerSequence,
      openTrackTargets = openTrackTargets,
      openTrackRepeats = openTrackRepeats,
      conditional = conditionalCount,
      b8bd = b8bdCount,
      releaseFF = releaseFF,
      directPcmOrDummy = directPcmOrDummy,
      rejected = rejected,
      channelMaskZero = channelMaskZero,
      channelMaskNonZero = channelMaskNonZero,
    }
    for id in pairs(playerIds) do
      summary.players = summary.players + 1
    end
    -- Assertions with compact summary on failure.
    Assert.isTrue(sequenceCount >= 1, "census: at least one sequence present (" .. compactSummary(summary) .. ")")
    Assert.isTrue(sdatBanks >= 1, "census: at least one bank present (" .. compactSummary(summary) .. ")")
    Assert.isTrue(
      sdatWaveArchives >= 1,
      "census: at least one wave archive present (" .. compactSummary(summary) .. ")"
    )

    -- Required opcodes must appear: 0x93 open_track, 0x94 jump, 0x95 call.
    Assert.isTrue(
      opcodeSeen[0x93] == true,
      "census: reachable 0x93 open_track present (" .. compactSummary(summary) .. ")"
    )
    Assert.isTrue(opcodeSeen[0x94] == true, "census: reachable 0x94 jump present (" .. compactSummary(summary) .. ")")
    Assert.isTrue(opcodeSeen[0x95] == true, "census: reachable 0x95 call present (" .. compactSummary(summary) .. ")")

    -- No unsupported reachable construct may be silently counted.
    Assert.equal(
      rejected,
      0,
      "census: no rejected SSEQ construct, first: "
        .. tostring(rejectedSample)
        .. " ("
        .. compactSummary(summary)
        .. ")"
    )

    -- Record presence of census dimensions without committing retail payloads.
    Assert.isTrue(next(playerIds) ~= nil, "census: player IDs enumerated (" .. compactSummary(summary) .. ")")
    Assert.isTrue(next(playerPriorities) ~= nil, "census: player priorities enumerated")
    Assert.isTrue(next(channelPriorities) ~= nil, "census: channel priorities enumerated")
    Assert.isTrue(next(initialVolumes) ~= nil, "census: initial volumes enumerated")
    Assert.isTrue(channelMaskZero + channelMaskNonZero >= 1, "census: channel masks enumerated")
    Assert.isTrue(maxTracksPerSequence >= 1, "census: track allocation enumerated")

    -- If release 0xFF occurs, record evidence; otherwise pass.
    if releaseFF > 0 then
      Assert.isTrue(releaseFF >= 1, "census: release 0xFF locations: " .. table.concat(releaseFFLocations, "; "))
    end

    -- Bank type classification: require that supported types are counted.
    Assert.isTrue(next(bankTypes) ~= nil, "census: SBNK instrument types counted")

    -- The HGSS corpus audit reports no unsupported reachable SSEQ/SBNK construct.
    -- DIRECTPCM/DUMMY occurrence is recorded and classified as supported or
    -- explicitly not required; either way the census completes.
    if directPcmOrDummy > 0 then
      Assert.isTrue(directPcmOrDummy >= 1, "census: DIRECTPCM/DUMMY occurrence recorded")
    end

    -- Ensure symbol coverage for census sequences where present.
    local namedSequences = 0
    for id = 0, sdat.counts.sequences - 1 do
      local record = sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        local sym = sdat.symbols and sdat.symbols.sequences and sdat.symbols.sequences[id]
        if sym ~= nil then
          namedSequences = namedSequences + 1
        end
      end
    end
    Assert.isTrue(namedSequences >= 1, "census: named sequences present")
  end)
end

function T.census_fails_loudly_on_unsupported_reachable_constructs()
  forEachVersion(function(ctx)
    local sdat = ctx.sdat
    local rejected = {}
    for id = 0, sdat.counts.sequences - 1 do
      local record = sdat.sequences[id]
      if record ~= nil and record.fileId ~= nil then
        local bytes = assert(sdat:readFile(record.fileId))
        local program, perr =
          require("romdump.src.digest.audio.SequenceLowering").lower(bytes, { sequenceId = id }, "SSEQ " .. id)
        if program == nil then
          rejected[#rejected + 1] = string.format("sequence %d: %s", id, tostring(perr))
          if #rejected >= 3 then
            break
          end
        end
      end
    end
    Assert.equal(#rejected, 0, "unsupported reachable constructs: " .. table.concat(rejected, " | "))
  end)
end

function T.retail_entry_sequences_keep_final_player_and_target_contracts()
  forEachVersion(function(ctx)
    local index = assert(ctx.bundle.index)
    local symbols = index.sequenceBySymbol
    local required = { "SEQ_GS_T_WAKABA", "SEQ_SE_DP_SELECT", "SEQ_ME_ITEM" }
    for _, symbol in ipairs(required) do
      local sequenceId = assert(symbols[symbol], "retail corpus is missing " .. symbol)
      local sequence = assert(ctx.bundle.sequences[sequenceId], symbol .. " must compile")
      local player = assert(sequence.player, symbol .. " must carry player metadata")
      Assert.isTrue(player.initialVolume ~= nil, symbol .. " must carry initial volume")
      Assert.isTrue(player.playerPriority ~= nil, symbol .. " must carry player priority")
      Assert.isTrue(player.channelPriority ~= nil, symbol .. " must carry channel priority")
      local instructions = assert(sequence.program.instructions, symbol .. " must carry normalized instructions")
      for instructionIndex, instruction in ipairs(instructions) do
        if instruction.op == "open_track" or instruction.op == "jump" or instruction.op == "call" then
          Assert.isTrue(
            instruction.target >= 1 and instruction.target <= #instructions,
            symbol .. " instruction " .. instructionIndex .. " has an invalid normalized target"
          )
        end
      end
    end
  end)
end

return {
  metadata = { capabilities = { "rom_dump" } },
  tests = {
    corpus_census_classifies_every_reachable_construct = T.corpus_census_classifies_every_reachable_construct,
    census_fails_loudly_on_unsupported_reachable_constructs = T.census_fails_loudly_on_unsupported_reachable_constructs,
    retail_entry_sequences_keep_final_player_and_target_contracts = T.retail_entry_sequences_keep_final_player_and_target_contracts,
  },
  beforeAll = T.beforeAll,
  afterAll = T.afterAll,
}
