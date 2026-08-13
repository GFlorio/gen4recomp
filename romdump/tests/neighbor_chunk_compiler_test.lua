-- NeighborChunkCompiler binds a streamed neighbour cell against the map-texture
-- pack of that cell's own area-data record, selected from the matrix header id --
-- the resource the cell's model was authored against, and a deliberate divergence
-- from the engine's single entry-area TEX0 (see the module header). A name the
-- pack does not define is reported, not fatal.

local Assert = require("tests.support.Assert")
local NeighborChunkCompiler = require("romdump.src.digest.NeighborChunkCompiler")
local LandDataBuilder = require("tests.support.LandDataBuilder")
local BdhcBuilder = require("tests.support.BdhcBuilder")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local NB = require("tests.support.NitroBuilder")

local T = {}

local LAND_MEMBER = 432
local AREA_MEMBER = 10
local CELL_PACK_ID = 10
local CELL_TEXTURE = "cell_tex"
local CELL_PALETTE = "cell_pal"

-- A land member whose map model requires exactly the cell pack's names.
local function landMember()
  return LandDataBuilder.build({
    model = NsbmdFixture.build({
      textureName = CELL_TEXTURE,
      paletteName = CELL_PALETTE,
      origHeight = 8,
      triangle = { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 3 } },
    }),
    bdhc = BdhcBuilder.build(),
  })
end

local function areaMember(mapTexturePackId)
  return NB.u16(0) .. NB.u16(mapTexturePackId) .. NB.u16(0) .. NB.u8(0) .. NB.u8(0)
end

-- opts.pack: { textures, palettes } for map_textures member CELL_PACK_ID.
local function romFsFor(opts)
  opts = opts or {}
  local members = {
    land_data = { [LAND_MEMBER] = landMember() },
    area_data = { [AREA_MEMBER] = areaMember(CELL_PACK_ID) },
    map_textures = {
      [CELL_PACK_ID] = Tex0Fixture.btx0(opts.pack or {
        textures = { CELL_TEXTURE },
        palettes = { CELL_PALETTE },
      }),
    },
  }
  return {
    openNarc = function(_, alias)
      local byId = assert(members[alias], "unexpected archive " .. alias)
      local highest = 0
      for id in pairs(byId) do
        highest = math.max(highest, id)
      end
      return {
        memberCount = function()
          return highest + 1
        end,
        readMember = function(_, memberId)
          return assert(byId[memberId], string.format("fixture %s has no member %d", alias, memberId))
        end,
      }
    end,
  }
end

function T.binds_against_the_neighbour_cells_own_area_pack()
  local chunk = NeighborChunkCompiler.compile(
    romFsFor(),
    LAND_MEMBER,
    AREA_MEMBER,
    { mapId = 457, mapSymbol = "MAP_X", neighborCells = { { x = 1, z = 2 } } }
  )

  Assert.equal(#chunk.batches, 2)
  Assert.equal(chunk.materials[1].name, "mat0")
  Assert.notNil(chunk.materials[1].texture)
  Assert.equal(#chunk.collision.cells, 1024)
  Assert.equal(chunk.collision.width, 32)
  Assert.equal(chunk.terrain.source.landDataMemberId, LAND_MEMBER)
end

function T.an_unresolved_name_reports_the_cell_own_pack_as_the_source()
  local romFs = romFsFor({ pack = { textures = { "other" }, palettes = { "other_pal" } } })
  local chunk = NeighborChunkCompiler.compile(romFs, LAND_MEMBER, AREA_MEMBER, { mapId = 457 })

  Assert.isNil(chunk.materials[1].texture)
  Assert.equal(#chunk.unresolved, 1)
  local entry = chunk.unresolved[1]
  Assert.equal(entry.role, "neighbor")
  Assert.equal(entry.name, CELL_TEXTURE)
  Assert.equal(entry.modelMemberId, LAND_MEMBER)
  Assert.equal(entry.source, "map_textures member " .. CELL_PACK_ID)
end

return { tests = T }
