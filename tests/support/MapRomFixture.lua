-- Assembles a synthetic RomFs-shaped object sufficient for a complete
-- MapAssetCompiler.compile of MAP_NEW_BARK_ELMS_LAB_1F: a 1x1 map matrix (so no
-- neighbour ring is planned), the area-data record naming the map and building
-- texture packs, a land member carrying one placed building, both texture packs,
-- the interior building-model archive, and a field-light profile. Every archive
-- is independently overridable so tests can give terrain and buildings
-- deliberately disjoint texture names and observe which pack each model is bound
-- to. Test-only.

local NB = require("tests.support.NitroBuilder")
local LandDataBuilder = require("tests.support.LandDataBuilder")
local BdhcBuilder = require("tests.support.BdhcBuilder")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")

local MapRomFixture = {}

MapRomFixture.MAP_SYMBOL = "MAP_NEW_BARK_ELMS_LAB_1F"
MapRomFixture.MAP_ID = 61
MapRomFixture.MATRIX_MEMBER_ID = 100
MapRomFixture.AREA_DATA_MEMBER_ID = 25
MapRomFixture.LAND_DATA_MEMBER_ID = 244
MapRomFixture.BUILDING_MODEL_MEMBER_ID = 38
MapRomFixture.MAP_TEXTURE_PACK_ID = 3
MapRomFixture.BUILDING_TEXTURE_PACK_ID = 7

-- Distinct names per pack so a test can tell which pack a model resolved from.
MapRomFixture.MAP_TEXTURE = "map_tex"
MapRomFixture.MAP_PALETTE = "map_pal"
MapRomFixture.BUILDING_TEXTURE = "bld_tex"
MapRomFixture.BUILDING_PALETTE = "bld_pal"

local LIGHT_PATH_PREFIX = "data/area"

-- What building_textures stores for an area with no placed buildings: four
-- bytes, not a Nitro file.
local PLACEHOLDER_PACK = "\0\0\0\0"

-- One field-light record block (CRLF): threshold, 4 light slots, 4 colours.
local function lightProfileText()
  local off = "0,0,0,0,0,0,0,"
  local block = table.concat({
    "0,",
    "1,11,11,11,-296,-296,-296,",
    off,
    off,
    off,
    "14,14,16,",
    "10,10,10,",
    "14,14,16,",
    "8,8,11,",
    "",
  }, "\r\n")
  return block .. "\r\nEOF\r\n"
end

-- A 1x1 matrix with neither headers nor altitudes, referencing one land member.
local function matrixMember(landMemberId)
  local name = "m_labo01_"
  return NB.u8(1) .. NB.u8(1) .. NB.u8(0) .. NB.u8(0) .. NB.u8(#name) .. name .. NB.u16(landMemberId)
end

local function areaMember(opts)
  return NB.u16(opts.buildingTexturePackId)
    .. NB.u16(opts.mapTexturePackId)
    .. NB.u16(0)
    .. NB.u8(0)
    .. NB.u8(opts.lightTypeRaw or 0) -- areaType 0 == indoor
end

-- opts (all optional):
--   landModel           NSBMD bytes for the central terrain model
--   buildingModel       NSBMD bytes for the placed building member
--   buildings           the land member's raw placement records, default one
--                       record referencing BUILDING_MODEL_MEMBER_ID
--   mapPack             { textures, palettes } for the map texture pack
--   buildingPack        { textures, palettes } for the building texture pack, or
--                       false for the four-byte placeholder the ROM stores when
--                       an area has no placed buildings
--   buildingTexturePackId / mapTexturePackId
-- Returns romFs, members -- the latter keyed by archive alias for sha assertions.
function MapRomFixture.build(opts)
  opts = opts or {}
  local mapTexturePackId = opts.mapTexturePackId or MapRomFixture.MAP_TEXTURE_PACK_ID
  local buildingTexturePackId = opts.buildingTexturePackId or MapRomFixture.BUILDING_TEXTURE_PACK_ID

  local landModel = opts.landModel
    or NsbmdFixture.build({
      modelName = "labo01",
      textureName = MapRomFixture.MAP_TEXTURE,
      paletteName = MapRomFixture.MAP_PALETTE,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    })
  local buildingModel = opts.buildingModel
    or NsbmdFixture.build({
      modelName = "leage_o03",
      textureName = MapRomFixture.BUILDING_TEXTURE,
      paletteName = MapRomFixture.BUILDING_PALETTE,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    })

  local members = {
    map_matrices = { [MapRomFixture.MATRIX_MEMBER_ID] = matrixMember(MapRomFixture.LAND_DATA_MEMBER_ID) },
    area_data = {
      [MapRomFixture.AREA_DATA_MEMBER_ID] = areaMember({
        mapTexturePackId = mapTexturePackId,
        buildingTexturePackId = buildingTexturePackId,
        lightTypeRaw = opts.lightTypeRaw,
      }),
    },
    land_data = {
      [MapRomFixture.LAND_DATA_MEMBER_ID] = LandDataBuilder.build({
        buildings = opts.buildings or LandDataBuilder.buildingRecord(MapRomFixture.BUILDING_MODEL_MEMBER_ID),
        model = landModel,
        bdhc = BdhcBuilder.build(),
      }),
    },
    map_textures = {
      [mapTexturePackId] = Tex0Fixture.btx0(opts.mapPack or {
        textures = { MapRomFixture.MAP_TEXTURE },
        palettes = { MapRomFixture.MAP_PALETTE },
      }),
    },
    building_textures = {
      [buildingTexturePackId] = opts.buildingPack == false and PLACEHOLDER_PACK
        or Tex0Fixture.btx0(opts.buildingPack or {
          textures = { MapRomFixture.BUILDING_TEXTURE },
          palettes = { MapRomFixture.BUILDING_PALETTE },
        }),
    },
    interior_build_models = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = buildingModel },
    -- Animation-list archives: one 0x18-byte record per model member; the
    -- default record carries no animations (first u16 0xFFFF). The shared
    -- animation archive is never read when no record references it.
    interior_build_anim_list = opts.interiorBuildAnimList
      or { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = NB.u16(0xFFFF) .. string.rep("\0", 0x16) },
    build_anim = opts.buildAnim or { [0] = "\0" },
  }

  local romFs = {
    openNarc = function(_, alias)
      local byId = members[alias]
      assert(byId, "fixture has no archive " .. alias)
      local highest = 0
      for id in pairs(byId) do
        highest = math.max(highest, id)
      end
      return {
        memberCount = function()
          return highest + 1
        end,
        readMember = function(_, memberId)
          -- Collapse to one value: `return assert(...)` would leak the assert
          -- message as a second return value into argument-list consumers.
          local bytes = assert(byId[memberId], string.format("fixture %s has no member %d", alias, memberId))
          return bytes
        end,
      }
    end,
    readSourcePath = function(_, path)
      assert(
        path:sub(1, #LIGHT_PATH_PREFIX) == LIGHT_PATH_PREFIX,
        "fixture only serves field-light profiles, got " .. path
      )
      return lightProfileText()
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return romFs, members
end

return MapRomFixture
