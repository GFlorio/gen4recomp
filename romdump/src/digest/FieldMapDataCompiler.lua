-- Compiles one semantic HGSS map's binary zone-event member into the normalized
-- lightweight field-map cache schema, plus the field-audio policy: the canonical
-- day/night music references with the frozen flag-driven overrides and surfing
-- traversal override, and the semantic soundplate records resolved from the
-- map's land BGS payload through the frozen soundplate table.

local Errors = require("libs.errors.src.Errors")
local ZoneEvents = require("romdump.src.digest.ZoneEvents")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapAnalysis = require("romdump.src.digest.MapAnalysis")
local MapMatrix = require("romdump.src.digest.MapMatrix")
local LandData = require("romdump.src.digest.LandData")
local HgssSoundplate = require("romdump.src.digest.HgssSoundplate")
local Hashing = require("romdump.src.digest.Hashing")
local fieldAudio = require("romdump.src.reference.hgss.field_audio")

local FieldMapDataCompiler = {}

-- The canonical audio sequence reference of a map-header music suffix: the
-- frozen catalog carries the SDAT symbol without its class prefix, and the
-- generated record carries the full reference so runtime field-music policy
-- never decorates symbols.
---@param suffix string
---@return string
local function canonicalSequence(suffix)
  return "SEQ_" .. suffix
end

-- The four disable rules of FieldSystem_SoundplateIsActive (HGSS
-- src/field/field_control.c): the Cianwood waterfall and Vermilion electric
-- barrier are gated on their gym map plus the sequence; Snorlax snoring and
-- the Rocket Hideout motor are gated by the sound alone on every map that
-- carries the plate. A plate without a matching rule is never disabled.
local DISABLE_RULES = {
  { soundId = 5, flagId = 0x981, map = "MAP_CIANWOOD_GYM" },
  { soundId = 15, flagId = 0x9A6, map = "MAP_VERMILION_GYM" },
  { soundId = 9, flagId = 0xF9 },
  { soundId = 10, flagId = 0xCA },
}

---@param soundId integer
---@param mapSymbol string
---@return integer|nil
local function disabledWhenFlag(soundId, mapSymbol)
  for _, rule in ipairs(DISABLE_RULES) do
    if rule.soundId == soundId and (rule.map == nil or rule.map == mapSymbol) then
      return rule.flagId
    end
  end
  return nil
end

-- The ordered source flag-music rules that apply to this map (the frozen
-- sys_flags.c table, in source order), as {flagId, sequence} records.
---@param mapSymbol string
---@return table
local function flagOverridesFor(mapSymbol)
  local overrides = {}
  for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
    if rule.map == mapSymbol then
      overrides[#overrides + 1] = { flagId = rule.flagId, sequence = rule.sequence }
    end
  end
  return overrides
end

-- The source traversal override, copied per record so the generated asset
-- never aliases the frozen producer table: an in-process consumer of one
-- bundle must not be able to mutate the shared reference for later compiles.
---@return table
local function traversalOverridesFor()
  local overrides = {}
  for _, rule in ipairs(fieldAudio.traversalOverrides) do
    overrides[#overrides + 1] = {
      traversal = rule.traversal,
      sequence = rule.sequence,
      unlessFlagId = rule.unlessFlagId,
    }
  end
  return overrides
end

-- The source sSoundplateVolume far/mid/close triple has three entries; a
-- plate whose volumeIndex is 0..2 emits the BGM duck / ambient moves, while
-- higher indices select/play with no volume move (the source's
-- GF_SndHandleMoveVolume calls are guarded).
local VOLUME_INDEX_TARGETS = 3

-- The semantic record for one decoded soundplate: the raw soundplateSoundID
-- never reaches the runtime asset, only the frozen sound-table facts and the
-- BGM duck / ambient targets from the volume index (levels above two emit
-- no volume moves, matching the source's guarded GF_SndHandleMoveVolume).
---@param record table
---@param ref table
---@param mapSymbol string
---@return table
local function semanticSoundplate(record, ref, mapSymbol)
  local plate = {
    x = record.x,
    z = record.z,
    xBounds = record.xBounds,
    zBounds = record.zBounds,
    sequence = ref.sequence,
    useFieldMusicBank = ref.useFieldMusicBank,
    volumeIndex = record.volumeIndex,
  }
  if record.volumeIndex < VOLUME_INDEX_TARGETS then
    plate.bgmTarget = fieldAudio.bgmDuckTargets[record.volumeIndex + 1]
    plate.ambientTarget = ref.ambientLevels[record.volumeIndex + 1]
  end
  plate.disabledWhenFlag = disabledWhenFlag(record.soundplateSoundID, mapSymbol)
  return plate
end

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function loadSource(romFs, sha1hex)
  sha1hex = sha1hex or Hashing.sha1hex
  local archiveInfo = romFs:resolvedNarc("zone_events")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "zone_events NARC is unavailable", { name = "zone_events" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("zone_events"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

-- The engine's SoundplateStruct is the whole land BGS block (field_control.c):
-- the 0x1234 signature bytes and a u16 record byte count precede the 8-byte
-- records, so the struct header is the BGS block header, not part of the
-- payload LandData exposes.
---@param land table
---@return string
local function bgsBlock(land)
  local payload = land.bgs.payload
  local size = #payload
  return string.char(
    land.bgs.signature % 256,
    math.floor(land.bgs.signature / 256) % 256,
    size % 256,
    math.floor(size / 256) % 256
  ) .. payload
end

-- The map's soundplates and the land/matrix source sha1s. Maps the matrix
-- cannot render (the default header filler and the unused headers) carry no
-- land payload and emit an empty soundplates array, exactly like maps whose
-- land BGS payload is empty.
---@return table plates, table audioSource { matrixMemberSha1, landDataMemberId?, landDataMemberSha1? }
local function compileSoundplates(romFs, map, sha1hex)
  local matrixNarc = must(romFs:openNarc("map_matrices"))
  local matrixBytes = must(matrixNarc:readMember(map.matrixMemberId))
  local matrix = must(MapMatrix.decode(matrixBytes, map.id))
  local analysis = MapAnalysis.analyzeRecord(map, matrix)
  if analysis.status ~= "resolved" then
    return {}, { matrixMemberSha1 = sha1hex(matrixBytes) }
  end

  local landNarc = must(romFs:openNarc("land_data"))
  local landBytes = must(landNarc:readMember(analysis.landDataMemberId))
  local land = must(LandData.decode(landBytes, {
    mapId = map.id,
    alias = "land_data",
    memberId = analysis.landDataMemberId,
  }))
  local plates = {}
  if #land.bgs.payload > 0 then
    local records = must(HgssSoundplate.decode(bgsBlock(land), {
      mapId = map.id,
      memberId = analysis.landDataMemberId,
    }))
    for index, record in ipairs(records) do
      local ref = fieldAudio.soundplates[record.soundplateSoundID + 1]
      if not ref then
        Errors.raise(
          "FIELD_MAP_UNKNOWN_SOUNDPLATE_SOUND",
          "land soundplate references unknown sound id " .. record.soundplateSoundID,
          { mapId = map.id, recordIndex = index - 1, soundplateSoundID = record.soundplateSoundID }
        )
      end
      plates[index] = semanticSoundplate(record, ref, map.symbol)
    end
  end
  return plates,
    {
      matrixMemberSha1 = sha1hex(matrixBytes),
      landDataMemberId = analysis.landDataMemberId,
      landDataMemberSha1 = sha1hex(landBytes),
    }
end

local function compileMap(romFs, map, source, sha1hex, hashLua)
  local memberBytes = must(source.archive:readMember(map.eventMemberId))
  local decoded = must(ZoneEvents.decode(memberBytes, {
    mapId = map.id,
    eventMemberId = map.eventMemberId,
    source = "fielddata_eventdata_zone_event",
  }))

  local memberSha1 = sha1hex(memberBytes)
  local soundplates, audioSource = compileSoundplates(romFs, map, sha1hex)
  local dependencies = {
    cacheFormat = FieldMapDataCache.FORMAT,
    mapCatalogVersion = MapCatalog.VERSION,
    versionRomSha1 = romFs:metadata().sha1,
    eventNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
    eventMemberId = map.eventMemberId,
    eventMemberSha1 = memberSha1,
    -- The map-matrix and land members the audio policy derives from: the
    -- matrix cell picks the land member, whose BGS payload carries the
    -- soundplates. Source identity lives only in this dependency record.
    matrixMemberSha1 = audioSource.matrixMemberSha1,
    landDataMemberId = audioSource.landDataMemberId,
    landDataMemberSha1 = audioSource.landDataMemberSha1,
  }
  local field = {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = map.id,
    mapSymbol = map.symbol,
    cameraType = map.cameraType,
    -- Map-header message/script associations (src/data/map_headers.h via the
    -- frozen catalog). Runtime code must never branch on map IDs to choose a
    -- bank; it reads these fields.
    messageBankId = map.messageMemberId,
    scriptBankId = map.scriptsMemberId,
    -- The map-header day/night music references (the frozen catalog's
    -- dayMusic/nightMusic, emitted as canonical audio sequence references);
    -- the field-music policy selects the day or night branch at runtime from
    -- this generated record, then applies the ordered flag overrides for this
    -- map and the source surfing traversal override (higher precedence than a
    -- persisted field-music override, before the map-header music unless the
    -- suppressing flag is set).
    music = {
      day = canonicalSequence(map.dayMusic),
      night = canonicalSequence(map.nightMusic),
      flagOverrides = flagOverridesFor(map.symbol),
      traversalOverrides = traversalOverridesFor(),
    },
    events = {
      background = decoded.backgroundEvents,
      objects = decoded.objectEvents,
      warps = decoded.warps,
      coordinates = decoded.coordinateEvents,
    },
    soundplates = soundplates,
  }
  local marker = FieldMapDataCache.marker(romFs:metadata().sha1, map.id, hashLua(dependencies))
  return { mapId = map.id, field = field, dependencies = dependencies, marker = marker }
end

local function _compile(romFs, idOrSymbol, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  return compileMap(romFs, MapCatalog.require(idOrSymbol), loadSource(romFs, sha1hex), sha1hex, hashLua)
end

function FieldMapDataCompiler.compile(romFs, idOrSymbol, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, idOrSymbol, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

function FieldMapDataCompiler.compileAll(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compileAll requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = pcall(function()
    local source = loadSource(romFs, sha1hex)
    local bundles = {}
    for map in MapCatalog.all() do
      bundles[#bundles + 1] = compileMap(romFs, map, source, sha1hex, hashLua)
    end
    return bundles
  end)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldMapDataCompiler
