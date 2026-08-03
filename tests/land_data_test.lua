local Assert = require("tests.support.Assert")
local LandData = require("src.data.LandData")
local Builder = require("tests.support.LandDataBuilder")

local T = {}

function T.decodes_valid_member_with_empty_bgs_payload()
  local land = assert(LandData.decode(Builder.build()))
  Assert.equal(land.bgs.signature, 0x1234)
  Assert.equal(land.bgs.payload, "")

  -- Sections follow the size header (0x10) + BGS block (0x04) with empty payload.
  Assert.equal(land.offsets.permissions, 0x14)
  Assert.equal(land.offsets.buildings, 0x14 + 0x800)
  Assert.equal(land.offsets.model, 0x14 + 0x800)
  Assert.equal(land.sizes.permissions, 0x800)
  Assert.equal(land.sizes.buildings, 0)
  Assert.equal(land.sizes.model, 0x10)
  Assert.equal(land.sizes.bdhc, 0)

  -- Permissions decode to a usable grid, buildings to an empty list.
  Assert.notNil(land.permissions:get(0, 0))
  Assert.equal(#land.buildings, 0)
  Assert.equal(land.mapModelBytes:sub(1, 4), "BMD0")
  Assert.equal(land.bdhcBytes, "")

  -- The raw 0x800-byte permission slice is exposed for the derived cache.
  Assert.equal(#land.permissionBytes, 0x800)
end

-- Regression for New Bark: a non-empty BGS/soundplate payload must shift the
-- permission grid, proving the offset is derived from the encoded size and not
-- fixed at 0x14. The 88 bytes are payload only; they exclude the 4-byte
-- (0x1234 + size) BGS header.
function T.derives_permission_offset_from_nonempty_bgs_payload()
  local payload = string.rep(string.char(0xAB), 88)
  local land = assert(LandData.decode(Builder.build({ bgsPayload = payload })))
  Assert.equal(#land.bgs.payload, 88)
  Assert.equal(land.bgs.payload, payload) -- preserved byte-for-byte
  Assert.equal(land.offsets.bgs, 0x10)
  Assert.equal(land.offsets.permissions, 0x14 + 88)
  Assert.equal(land.offsets.buildings, 0x14 + 88 + 0x800)
end

function T.decodes_buildings_and_bdhc()
  local land = assert(LandData.decode(Builder.build({
    buildings = Builder.buildingRecord(21) .. Builder.buildingRecord(7),
    bdhc = "BDHC" .. string.rep("\0", 12),
  })))
  Assert.equal(#land.buildings, 2)
  Assert.equal(land.buildings[1].modelMemberId, 21)
  Assert.equal(land.buildings[2].modelMemberId, 7)
  Assert.equal(land.sizes.bdhc, 16)
  Assert.equal(land.bdhcBytes:sub(1, 4), "BDHC")
end

function T.carries_source_context()
  local land = assert(LandData.decode(Builder.build(), { mapId = 61, alias = "land_data", memberId = 244 }))
  Assert.equal(land.source.memberId, 244)
end

local function decodeErr(bytes)
  local land, err = LandData.decode(bytes, { mapId = 61, alias = "land_data", memberId = 244 })
  Assert.isNil(land)
  Assert.notNil(err)
  return err
end

function T.rejects_member_too_small()
  Assert.equal(decodeErr("\0\0").code, "LAND_DATA_TOO_SMALL")
end

function T.rejects_bad_bgs_magic()
  Assert.equal(decodeErr(Builder.build({ bgsSignature = 0x0000 })).code, "LAND_DATA_BAD_BGS_MAGIC")
end

function T.rejects_section_sum_mismatch()
  Assert.equal(decodeErr(Builder.build() .. "\0").code, "LAND_DATA_BAD_SECTION_SUM")
end

function T.rejects_wrong_permission_size()
  local err = decodeErr(Builder.build({ permissions = string.rep("\0", 0x400) }))
  Assert.equal(err.code, "LAND_DATA_BAD_PERMISSION_SIZE")
end

function T.rejects_misaligned_building_section()
  local err = decodeErr(Builder.build({ buildings = string.rep("\0", 5) }))
  Assert.equal(err.code, "LAND_DATA_BAD_BUILDING_SIZE")
end

function T.rejects_bad_model_magic()
  local err = decodeErr(Builder.build({ model = "XXXX" .. string.rep("\0", 12) }))
  Assert.equal(err.code, "LAND_DATA_BAD_MODEL_MAGIC")
end

function T.rejects_bad_bdhc_magic()
  local err = decodeErr(Builder.build({ bdhc = "XXXX" .. string.rep("\0", 12) }))
  Assert.equal(err.code, "LAND_DATA_BAD_BDHC_MAGIC")
end

function T.error_context_names_the_source_member()
  local err = decodeErr(Builder.build({ bgsSignature = 0 }))
  Assert.equal(err.context.source.memberId, 244)
  Assert.equal(err.context.source.mapId, 61)
end

return T
