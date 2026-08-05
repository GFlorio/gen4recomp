-- Compiles one semantic HGSS map's binary zone-event member into the normalized
-- lightweight field-map cache schema. Map identity and member selection come
-- exclusively from the frozen map catalog.

local Errors = require("libs.rom.src.Errors")
local ZoneEvents = require("libs.assets.src.ZoneEvents")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local Hashing = require("romdump.src.digest.Hashing")

local FieldMapDataCompiler = {}

FieldMapDataCompiler.COMPILER_VERSION = "field-map-data-compiler-v1"
FieldMapDataCompiler.DECODER_VERSION = "hgss-zone-events-v1"

local function must(value, err)
  if value == nil then error(err) end
  return value
end

local function loadSource(romFs, sha1hex)
  sha1hex = sha1hex or Hashing.sha1hex
  local archiveInfo = romFs:resolvedNarc("zone_events")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "zone_events NARC is unavailable",
      { name = "zone_events" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("zone_events"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
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
  local dependencies = {
    cacheFormat = FieldMapDataCache.FORMAT,
    compilerVersion = FieldMapDataCompiler.COMPILER_VERSION,
    decoderVersion = FieldMapDataCompiler.DECODER_VERSION,
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
  }
  local field = {
    schema = "g4-field-map-v1",
    mapId = map.id,
    mapSymbol = map.symbol,
    cameraType = map.cameraType,
    source = {
      eventNarc = "fielddata_eventdata_zone_event",
      eventMemberId = map.eventMemberId,
      eventMemberSha1 = memberSha1,
    },
    events = {
      background = decoded.backgroundEvents,
      objects = decoded.objectEvents,
      warps = decoded.warps,
      coordinates = decoded.coordinateEvents,
    },
  }
  local marker = FieldMapDataCache.marker(
    romFs:metadata().sha1, map.id, hashLua(dependencies))
  return { mapId = map.id, field = field, dependencies = dependencies, marker = marker }
end

local function _compile(romFs, idOrSymbol, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc,
    "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  return compileMap(romFs, MapCatalog.require(idOrSymbol),
    loadSource(romFs, sha1hex), sha1hex, hashLua)
end

function FieldMapDataCompiler.compile(romFs, idOrSymbol, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, idOrSymbol, sha1hex, hashLua)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

function FieldMapDataCompiler.compileAll(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc,
    "compileAll requires a RomFs-shaped object")
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
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return FieldMapDataCompiler
