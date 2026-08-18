-- ROM-gated soundplate/field-audio census over every ready game version. The
-- heavy production compile runs once per version in beforeAll: the full audio
-- bundle (AudioCompiler.compile over the real gs_sound_data.sdat), all 540
-- compiled field-map records (FieldMapDataCompiler.compileAll), and the raw
-- every-map land BGS payload decoded through the production LandData/HgssSoundplate
-- path. The scenarios then prove the assumptions the runtime contract relies on:
-- every non-empty land BGS payload conforms to the normalized SoundplateStruct
-- interpretation and every compiled soundplate record matches the source 16-entry
-- table (sequence, field-music-bank flag, duck/ambient targets, disable-flag
-- scope); every map-music policy reference and emitted soundplate sequence
-- resolves to a compiled sequence; every disable flag is a valid event-state
-- flag from the four source rules (field_control.c FieldSystem_SoundplateIsActive);
-- all environmental soundplate sequences share the single replaceable
-- environment player role the hardcoded ambient-volume handle implies; and
-- every useFieldMusicBank record's program references resolve under the
-- reachable field-music donor banks of its map, with the observed retail
-- silence (the basic bank's override/traversal states, the Battle Frontier
-- and water Safari Zone day/night banks) pinned exactly so the runtime never
-- adds fallback-to-own-bank behavior. This is the obligation that lets the
-- runtime omit raw sound IDs, source map/soundplate tables, and
-- fallback-to-own-bank behavior.

local Assert = require("tests.support.Assert")
local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local GameVersion = require("romdump.src.source.GameVersion")
local HgssSoundplate = require("romdump.src.digest.HgssSoundplate")
local LandData = require("romdump.src.digest.LandData")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapResolver = require("romdump.src.digest.MapResolver")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")
local Sdat = require("romdump.src.digest.audio.Sdat")
local fieldAudio = require("romdump.src.reference.hgss.field_audio")
local flags = require("romdump.src.reference.hgss.flags")

local SDAT_PATH = "data/sound/gs_sound_data.sdat"

-- The four disable rules of FieldSystem_SoundplateIsActive, re-derived from the
-- single frozen reference authority (field_audio.lua): each soundplate entry
-- carries its disableWhen {flagId, map?} -- a map-scoped rule applies only on
-- its named map, an unscoped rule on every map carrying that sound. The census
-- never maintains a second copy of the four rule constants.
local function expectedDisableFlag(soundId, mapSymbol)
  local rule = fieldAudio.soundplates[soundId + 1].disableWhen
  if rule ~= nil and (rule.map == nil or rule.map == mapSymbol) then
    return rule.flagId
  end
  return nil
end

local DISABLE_RULE_FLAGS = {}
for _, record in ipairs(fieldAudio.soundplates) do
  if record.disableWhen ~= nil then
    DISABLE_RULE_FLAGS[record.disableWhen.flagId] = true
  end
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
    local entry = { versionId = versionId }
    opened[#opened + 1] = entry
    local ok, err = pcall(function()
      entry.romFs = assert(RomFs.open(versionId))
      entry.sdatBytes = assert(entry.romFs:readSourcePath(SDAT_PATH), "cannot read " .. SDAT_PATH)
      entry.sdat = assert(Sdat.open(entry.sdatBytes, SDAT_PATH))
      entry.bundle = assert(AudioCompiler.compile(entry.romFs))
      entry.fieldBundles = assert(FieldMapDataCompiler.compileAll(entry.romFs))

      entry.soundById = {}
      for soundId, ref in ipairs(fieldAudio.soundplates) do
        entry.soundById[soundId - 1] = ref
      end

      -- The raw land BGS block per compiled map, through the production
      -- resolver/decoder, plus its normalized record interpretation. The
      -- engine's SoundplateStruct is the whole block (0x1234 signature + u16
      -- record byte count + records), so the decode input is the block, not
      -- the bare payload. Maps the resolver cannot render (the default header
      -- filler) and the one cell whose land member is the no-data sentinel
      -- (0xFFFF) have no land payload and no compiled duplicates.
      entry.landsById = {}
      for _, bundle in ipairs(entry.fieldBundles) do
        local resolved = MapResolver.resolve(entry.romFs, bundle.mapId)
        if resolved ~= nil and resolved.landDataMemberId ~= 0xFFFF then
          local bytes = assert(entry.romFs:openNarc("land_data"):readMember(resolved.landDataMemberId))
          local land = assert(LandData.decode(bytes, {
            mapId = bundle.mapId,
            alias = "land_data",
            memberId = resolved.landDataMemberId,
          }))
          local block
          if #land.bgs.payload > 0 then
            block = string.char(
              land.bgs.signature % 256,
              math.floor(land.bgs.signature / 256) % 256,
              #land.bgs.payload % 256,
              math.floor(#land.bgs.payload / 256) % 256
            ) .. land.bgs.payload
          end
          local records
          if block ~= nil then
            local okDecoded, decodeErr = HgssSoundplate.decode(block, {
              mapId = bundle.mapId,
              memberId = resolved.landDataMemberId,
            })
            Assert.isTrue(
              okDecoded ~= nil,
              "map "
                .. bundle.mapId
                .. " land BGS block does not conform to the soundplate interpretation: "
                .. tostring(decodeErr and decodeErr.message or decodeErr)
            )
            records = okDecoded
          end
          entry.landsById[bundle.mapId] = {
            payload = land.bgs.payload,
            block = block,
            memberId = resolved.landDataMemberId,
            records = records,
          }
        end
      end
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
  for _, ctx in ipairs(assert(contexts, "the soundplate census suite has no open contexts")) do
    local ok, err = pcall(fn, ctx)
    if not ok then
      error(ctx.versionId .. ": " .. tostring(err), 0)
    end
  end
end

-- Every non-empty land BGS payload decodes to the normalized record list; the
-- compiled soundplates array is its semantic mirror (same count and order, the
-- source table resolved for every sound id, exact coordinate survival, exact
-- duck/ambient targets from the volume index, and the disable flag from the
-- source scope). The walk also inventories the volume indices and proves the
-- trailing-payload relationship: the record block always spans the payload
-- exactly (no trailing bytes), the corpus evidence behind the decoder's
-- strict span requirement.
function T.every_land_bgs_payload_conforms_and_the_compiled_plates_match_the_source_table()
  forEachVersion(function(ctx)
    local platesSeen = 0
    local volumeIndexes = {}
    local trailingSizes = {}
    local mismatched = {}
    for _, bundle in ipairs(ctx.fieldBundles) do
      local field = bundle.field
      Assert.equal(type(field.music), "table", "every compiled field record carries a music record")
      local land = ctx.landsById[bundle.mapId]
      if land == nil then
        Assert.deepEqual(field.soundplates, {}, "an unresolvable map still emits an empty soundplates array")
      elseif land.payload == "" then
        Assert.deepEqual(field.soundplates, {}, "an empty BGS payload emits no soundplates")
      else
        local records = assert(land.records)
        Assert.equal(type(field.soundplates), "table", "a BGS payload emits a soundplates array")
        Assert.equal(#field.soundplates, #records, "compiled soundplate count matches the normalized interpretation")
        local expectedTail = #assert(land.block) - (4 + #records * 8)
        Assert.equal(expectedTail, 0, "the declared record block spans the payload exactly, with no trailing bytes")
        trailingSizes[expectedTail] = trailingSizes[expectedTail] or 0
        trailingSizes[expectedTail] = trailingSizes[expectedTail] + 1
        for index, raw in ipairs(records) do
          local plate = field.soundplates[index]
          local ref = ctx.soundById[raw.soundplateSoundID]
          if ref == nil then
            mismatched[#mismatched + 1] = bundle.mapId .. " sound id " .. raw.soundplateSoundID
          else
            Assert.equal(plate.x, raw.x, bundle.mapId .. " plate " .. index .. " x")
            Assert.equal(plate.z, raw.z, bundle.mapId .. " plate " .. index .. " z")
            Assert.equal(plate.xBounds, raw.xBounds, bundle.mapId .. " plate " .. index .. " xBounds")
            Assert.equal(plate.zBounds, raw.zBounds, bundle.mapId .. " plate " .. index .. " zBounds")
            Assert.equal(plate.sequence, ref.sequence, bundle.mapId .. " plate " .. index .. " sequence")
            Assert.equal(
              plate.useFieldMusicBank,
              ref.useFieldMusicBank,
              bundle.mapId .. " plate " .. index .. " bank flag"
            )
            Assert.isNil(plate.volumeIndex, bundle.mapId .. " plate " .. index .. " raw volume index leaks")
            Assert.isNil(plate.soundplateSoundID, bundle.mapId .. " plate " .. index .. " raw sound id leaks")
            volumeIndexes[raw.volumeIndex] = true
            if raw.volumeIndex >= 3 then
              Assert.isNil(plate.bgmTarget, bundle.mapId .. " plate " .. index .. " duck target above the range")
              Assert.isNil(plate.ambientTarget, bundle.mapId .. " plate " .. index .. " ambient target above the range")
            else
              Assert.equal(plate.bgmTarget, fieldAudio.bgmDuckTargets[raw.volumeIndex + 1])
              Assert.equal(plate.ambientTarget, ref.ambientLevels[raw.volumeIndex + 1])
            end
            local expectedFlag = expectedDisableFlag(raw.soundplateSoundID, field.mapSymbol)
            Assert.equal(plate.disabledWhenFlag, expectedFlag, bundle.mapId .. " plate " .. index .. " disable flag")
            platesSeen = platesSeen + 1
          end
        end
      end
    end
    Assert.equal(#mismatched, 0, "land payloads reference unknown sound ids: " .. table.concat(mismatched, ", "))
    Assert.isTrue(platesSeen >= 1, "the compiled corpus actually carries soundplate records")
    Assert.isTrue(next(volumeIndexes) ~= nil, "a volume index was observed")
    local listed = {}
    for raw in pairs(volumeIndexes) do
      listed[#listed + 1] = raw
    end
    table.sort(listed)
    for _, raw in ipairs(listed) do
      Assert.isTrue(raw >= 0 and raw % 1 == 0, "volume index " .. raw .. " is a whole number")
    end
    Assert.isTrue(next(trailingSizes) ~= nil, "the payload trailing relationship was observed")
  end)
end

-- Every map-music policy reference -- day/night, the flag overrides, the surf
-- traversal override -- and every emitted soundplate sequence resolves to a
-- compiled sequence through the audio index, and flag overrides attach only to
-- their own maps.
function T.map_music_policy_and_soundplate_sequences_resolve_to_compiled_sequences()
  forEachVersion(function(ctx)
    local bySymbol = ctx.bundle.index.sequenceBySymbol
    local ruleMaps = {}
    for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
      ruleMaps[rule.map] = true
    end
    local checked = 0
    for _, bundle in ipairs(ctx.fieldBundles) do
      local music = bundle.field.music
      Assert.equal(type(music.flagOverrides), "table", bundle.mapId .. " music carries a flagOverrides array")
      Assert.equal(type(music.traversalOverrides), "table", bundle.mapId .. " music carries a traversalOverrides array")
      Assert.notNil(bySymbol[music.day], bundle.mapId .. " day music does not resolve")
      Assert.notNil(bySymbol[music.night], bundle.mapId .. " night music does not resolve")
      for _, override in ipairs(music.flagOverrides) do
        Assert.isTrue(ruleMaps[bundle.field.mapSymbol] == true, "a flag override attached to a non-source map")
        Assert.notNil(bySymbol[override.sequence], bundle.mapId .. " flag override does not resolve")
        checked = checked + 1
      end
      for _, override in ipairs(music.traversalOverrides) do
        Assert.notNil(bySymbol[override.sequence], bundle.mapId .. " traversal override does not resolve")
      end
      for _, plate in ipairs(bundle.field.soundplates) do
        Assert.notNil(bySymbol[plate.sequence], bundle.mapId .. " soundplate sequence does not resolve")
        checked = checked + 1
      end
    end
    Assert.isTrue(checked >= 1, "the corpus walks at least one field-audio sequence reference")
  end)
end

-- Every emitted disable flag is one of the four source rules and a valid
-- project event-state flag id. Absence of the field is a valid "never disabled"
-- record; presence must obey the exact source scope recomputed in
-- every_land_bgs_payload_conforms_and_the_compiled_plates_match_the_source_table.
function T.disabled_flags_are_valid_event_state_flags_from_the_source_rules()
  forEachVersion(function(ctx)
    local seen = 0
    for _, bundle in ipairs(ctx.fieldBundles) do
      for _, plate in ipairs(bundle.field.soundplates) do
        local flag = plate.disabledWhenFlag
        if flag ~= nil then
          Assert.isTrue(
            DISABLE_RULE_FLAGS[flag] == true,
            bundle.mapId .. " plate disable flag 0x" .. string.format("%X", flag) .. " is not a source rule flag"
          )
          Assert.notNil(
            flags.byId[flag],
            bundle.mapId .. " plate disable flag 0x" .. string.format("%X", flag) .. " is not an event-state flag"
          )
          seen = seen + 1
        end
      end
    end
    Assert.isTrue(seen >= 1, "the corpus actually gates soundplates by flag")
  end)
end

-- The environmental soundplate sequences all resolve to the same playable
-- player, that player declares exactly one sequence slot, and the role is the
-- one the source's hardcoded ambient-volume move (GF_SndHandleMoveVolume(5, ...))
-- implies. This proves the environment player replacement model and lets the
-- runtime avoid hardcoding an environmental player number.
function T.environmental_soundplate_sequences_share_one_replaceable_player_role()
  forEachVersion(function(ctx)
    local bySymbol = ctx.bundle.index.sequenceBySymbol
    local players = {}
    local plates = 0
    for _, bundle in ipairs(ctx.fieldBundles) do
      for _, plate in ipairs(bundle.field.soundplates) do
        local sequenceId = bySymbol[plate.sequence]
        Assert.notNil(sequenceId, bundle.mapId .. " soundplate sequence resolves")
        local playerId = ctx.sdat.sequences[assert(sequenceId)].playerId
        players[playerId] = true
        plates = plates + 1
      end
    end
    Assert.isTrue(plates >= 1, "the corpus carries soundplate records")
    local ids = {}
    for playerId in pairs(players) do
      ids[#ids + 1] = playerId
    end
    table.sort(ids)
    Assert.deepEqual(ids, { 5 }, "every environmental sequence plays on the source ambient-move player")
    local player = ctx.sdat.players[assert(ids[1])]
    Assert.notNil(player, "the environmental player exists")
    Assert.equal(player.maxSequences, 1, "the environmental role declares one replaceable sequence slot")
  end)
end

-- The maps whose day/night music banks lack the water-flow program 104, so
-- the water-flow plate is silent in every non-override state on retail. The
-- source plays the environmental sequence with the bank of the currently
-- playing field music (sub_02006088: attr 0x20 -> GF_GetBankBySeqNo, no
-- coverage check, no fallback), so an uncovered program simply renders no
-- note. This pinned set is the observed retail silence; the runtime must
-- reproduce it, never add fallback-to-own-bank behavior.
local SILENT_DAY_NIGHT_MAPS = {
  MAP_BATTLE_FRONTIER = true,
  MAP_SAFARI_ZONE_02 = true,
  MAP_SAFARI_ZONE_05 = true,
  MAP_SAFARI_ZONE_06 = true,
  MAP_SAFARI_ZONE_08 = true,
  MAP_SAFARI_ZONE_09 = true,
}

-- For every useFieldMusicBank record, the reachable field-music states of its
-- map (day/night, the flag overrides, the surfing traversal override) donate
-- the playback bank. The census pins the observed coverage relationship: the
-- day/night banks cover every static environmental program except on the
-- pinned silent-music maps; the Rocket-takeover flag override
-- (SEQ_GS_EYE_ROCKET) and the surfing traversal (SEQ_GS_NAMINORI) both play
-- on the basic bank, which carries only instruments 0..59 and covers nothing
-- environmental; and the water-flow sequence's own bank lacks program 104, so
-- a fallback to the sequence's own bank is impossible there anyway. Absence of
-- a donor bank, an uncovered program outside the pinned silent set, or a
-- fallback-to-own-bank behavior is a compile/census error.
function T.field_music_bank_override_programs_resolve_under_the_donor_bank()
  forEachVersion(function(ctx)
    local bySymbol = ctx.bundle.index.sequenceBySymbol
    local eyeRocketMaps = {}
    for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
      if rule.sequence == "SEQ_GS_EYE_ROCKET" then
        eyeRocketMaps[rule.map] = true
      end
    end
    local checked = 0
    local traversalChecked = 0
    local silentDayNightChecked = 0
    local flagFailures = {}
    local flagOverridePlates = {}
    for _, bundle in ipairs(ctx.fieldBundles) do
      local donors = {}
      local function addDonor(kind, sequence)
        local sequenceId = bySymbol[sequence]
        Assert.notNil(sequenceId, bundle.mapId .. " donor sequence " .. sequence .. " resolves")
        local donorSequence = ctx.bundle.sequences[assert(sequenceId)]
        local bank = nil
        if donorSequence.bankId ~= 0xFFFF then
          bank = ctx.bundle.banks[donorSequence.bankId]
          Assert.notNil(bank, bundle.mapId .. " donor bank " .. sequence .. " resolves")
        end
        donors[#donors + 1] = { kind = kind, sequence = sequence, bank = bank }
      end
      addDonor("day", bundle.field.music.day)
      addDonor("night", bundle.field.music.night)
      for _, override in ipairs(bundle.field.music.flagOverrides) do
        addDonor("flag", override.sequence)
      end
      for _, override in ipairs(bundle.field.music.traversalOverrides) do
        addDonor("traversal", override.sequence)
      end
      for _, plate in ipairs(bundle.field.soundplates) do
        if plate.useFieldMusicBank then
          if eyeRocketMaps[bundle.field.mapSymbol] then
            flagOverridePlates[bundle.field.mapSymbol] = true
          end
          local environment = ctx.bundle.sequences[assert(bySymbol[plate.sequence])]
          local programs = {}
          for _, instruction in ipairs(environment.program.instructions) do
            if instruction.op == "program" then
              Assert.equal(
                type(instruction.program),
                "number",
                bundle.mapId .. " environmental sequence uses a dynamic program"
              )
              programs[#programs + 1] = instruction.program
            end
          end
          for _, donor in ipairs(donors) do
            local missing = {}
            for _, program in ipairs(programs) do
              if donor.bank == nil or donor.bank.instruments[program] == nil then
                missing[#missing + 1] = program
              end
              checked = checked + 1
            end
            if donor.kind == "traversal" then
              traversalChecked = traversalChecked + 1
              Assert.isTrue(
                #missing > 0,
                bundle.mapId .. " surfing traversal donor unexpectedly covers an environmental program"
              )
            elseif donor.kind == "flag" then
              if #missing > 0 then
                flagFailures[#flagFailures + 1] = {
                  map = bundle.field.mapSymbol,
                  sequence = donor.sequence,
                  missing = missing,
                }
              end
            elseif SILENT_DAY_NIGHT_MAPS[bundle.field.mapSymbol] == true then
              silentDayNightChecked = silentDayNightChecked + 1
              Assert.isTrue(
                #missing > 0,
                bundle.mapId
                  .. " pinned silent-music map's day/night donor unexpectedly covers an environmental program"
              )
            else
              Assert.equal(
                #missing,
                0,
                bundle.mapId
                  .. " day/night donor silently misses program(s) "
                  .. table.concat(missing, ",")
                  .. " outside the pinned silent set"
              )
            end
          end
        end
      end
    end
    Assert.isTrue(checked >= 1, "bank-override program references were actually checked")
    Assert.isTrue(traversalChecked >= 1, "surfing traversal donors were checked on bank-override plates")
    Assert.isTrue(
      silentDayNightChecked >= 1,
      "the pinned silent-music maps carry bank-override plates (Battle Frontier, the water Safari Zone maps)"
    )
    -- The only flag-override donors that fail are the Rocket-takeover
    -- overrides on their own two maps, and every such map with a plate fails.
    for _, failure in ipairs(flagFailures) do
      Assert.equal(
        failure.sequence,
        "SEQ_GS_EYE_ROCKET",
        failure.map .. " flag override donor fails outside the Rocket-takeover override"
      )
      Assert.isTrue(eyeRocketMaps[failure.map] == true, failure.map .. " is not a Rocket-takeover override map")
    end
    local failedEyeRocketMaps = {}
    for _, failure in ipairs(flagFailures) do
      failedEyeRocketMaps[failure.map] = true
    end
    for map in pairs(flagOverridePlates) do
      Assert.isTrue(
        failedEyeRocketMaps[map] == true,
        map .. " carries a bank-override plate but its Rocket-takeover flag override donor covers it"
      )
    end
  end)
end

return {
  metadata = { capabilities = { "rom_dump" } },
  beforeAll = T.beforeAll,
  afterAll = T.afterAll,
  tests = {
    every_land_bgs_payload_conforms_and_the_compiled_plates_match_the_source_table = T.every_land_bgs_payload_conforms_and_the_compiled_plates_match_the_source_table,
    map_music_policy_and_soundplate_sequences_resolve_to_compiled_sequences = T.map_music_policy_and_soundplate_sequences_resolve_to_compiled_sequences,
    disabled_flags_are_valid_event_state_flags_from_the_source_rules = T.disabled_flags_are_valid_event_state_flags_from_the_source_rules,
    environmental_soundplate_sequences_share_one_replaceable_player_role = T.environmental_soundplate_sequences_share_one_replaceable_player_role,
    field_music_bank_override_programs_resolve_under_the_donor_bank = T.field_music_bank_override_programs_resolve_under_the_donor_bank,
  },
}
