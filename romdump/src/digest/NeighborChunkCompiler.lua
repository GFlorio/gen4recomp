-- Compiles a single land chunk's terrain into in-memory draw batches, for the
-- presentation-only neighbor ring. Unlike MapAssetCompiler it does not resolve a
-- semantic map, emit a scene descriptor, or touch the derived cache: it takes an
-- explicit land-data member and area-data member (the neighbor cell's, resolved
-- from the matrix header id), decodes the area/land/map-model/map-texture pack,
-- and reuses MapAssetCompiler.compileModel to produce the same content-addressed
-- batches/meshes/textures. Placed buildings are intentionally skipped -- the ring
-- is terrain-only. Runs under LÖVE (needs an open RomFs); raw Nitro formats stop
-- here just as in the main compiler.

local AreaData = require("romdump.src.digest.AreaData")
local LandData = require("romdump.src.digest.LandData")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")

local NeighborChunkCompiler = {}

local function readMember(narc, alias, memberId)
  local count = narc:memberCount()
  assert(memberId >= 0 and memberId < count,
    string.format("%s member %d out of range (count %d)", alias, memberId, count))
  return assert(narc:readMember(memberId))
end

-- Compile land member `landMemberId` (textured through the map-texture pack of
-- `areaMemberId`) into { batches, materials, meshes, textures }.
function NeighborChunkCompiler.compile(romFs, landMemberId, areaMemberId)
  local areaBytes = readMember(assert(romFs:openNarc("area_data")), "area_data", areaMemberId)
  local area = assert(AreaData.decode(areaBytes, { alias = "area_data", memberId = areaMemberId }))

  local landBytes = readMember(assert(romFs:openNarc("land_data")), "land_data", landMemberId)
  local land = assert(LandData.decode(landBytes,
    { alias = "land_data", memberId = landMemberId }))

  local mapNsbmd = assert(Nsbmd.decode(land.mapModelBytes,
    { alias = "land_data", memberId = landMemberId, section = "map-model" }))
  local mapModel = mapNsbmd.models[1]

  local texBytes = readMember(assert(romFs:openNarc("map_textures")), "map_textures", area.mapTexturePackId)
  local texPack = assert(Nsbtx.decode(texBytes,
    { alias = "map_textures", memberId = area.mapTexturePackId }))

  local meshes, textures = {}, {}
  local compiled = MapAssetCompiler.compileModel(mapModel, texPack, meshes, textures,
    { model = "neighbor", memberId = landMemberId })

  return {
    batches = compiled.batches,
    materials = compiled.materials,
    meshes = meshes,
    textures = textures,
  }
end

return NeighborChunkCompiler
