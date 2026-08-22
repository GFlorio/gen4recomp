-- Assembles a synthetic RomFs-shaped object sufficient for a deterministic
-- FieldMapDataCompiler.compile of any catalog map: a zone-event member, a 1x1
-- map matrix that resolves every map id to one land member (the map matrix
-- header set is absent, so every cell defaults to the compiled map's own id),
-- and that land member carrying the test's BGS soundplate payload. Matches the
-- production romFs surface (resolvedNarc/openNarc/read/metadata/version), so
-- fixture tests behave like a real-dump compile without needing one, and the
-- fixture works identically whether the compiler resolves land data through
-- the map matrix or receives it some other way. Test-only.

local NB = require("tests.support.NitroBuilder")
local LandDataBuilder = require("tests.support.LandDataBuilder")
local ZoneEventsBuilder = require("tests.support.ZoneEventsBuilder")

local FieldMapDataFixture = {}

FieldMapDataFixture.LAND_MEMBER_ID = 244
FieldMapDataFixture.MATRIX_MEMBER_ID = 100
FieldMapDataFixture.EVENT_MEMBER_ID = 57

-- A 1x1 map-matrix member with no header/altitude sections, so MapMatrix
-- defaults every cell to the compiled map's id and selects the one land member.
function FieldMapDataFixture.matrixMember(landMemberId)
  local name = "mat1"
  return NB.u8(1) .. NB.u8(1) .. NB.u8(0) .. NB.u8(0) .. NB.u8(#name) .. name .. NB.u16(landMemberId)
end

-- opts (all optional):
--   zoneEventsMember  raw zone-event member bytes (default an empty events record)
--   landBgsPayload    the land member's BGS/soundplate payload (default "")
--   landMemberId / matrixMemberId / eventMemberId
--   members           extra { alias = { memberId = bytes } } merged in
---@param opts table|nil
---@return table romFs
function FieldMapDataFixture.build(opts)
  opts = opts or {}
  local landMemberId = opts.landMemberId or FieldMapDataFixture.LAND_MEMBER_ID
  local matrixMemberId = opts.matrixMemberId or FieldMapDataFixture.MATRIX_MEMBER_ID
  local eventMemberId = opts.eventMemberId or FieldMapDataFixture.EVENT_MEMBER_ID

  local members = {
    map_matrices = { [matrixMemberId] = FieldMapDataFixture.matrixMember(landMemberId) },
    land_data = {
      [landMemberId] = LandDataBuilder.build({ bgsPayload = opts.landBgsPayload or "" }),
    },
    zone_events = { [eventMemberId] = opts.zoneEventsMember or ZoneEventsBuilder.build() },
    field_script_headers = { [opts.scriptHeaderMemberId or 618] = opts.scriptHeaderMember or "" },
  }
  for alias, byId in pairs(opts.members or {}) do
    for memberId, bytes in pairs(byId) do
      members[alias] = members[alias] or {}
      members[alias][memberId] = bytes
    end
  end

  local romFs = {
    resolvedNarc = function(_, alias)
      if alias == "zone_events" then
        return {
          symbol = "NARC_fielddata_eventdata_zone_event",
          alias = "zone_events",
          narcId = 32,
          fileId = 99,
          path = "a/0/3/2",
        }
      end
      return { symbol = "NARC_" .. alias, alias = alias, narcId = 1, fileId = 1, path = "a/0/0/1" }
    end,
    openNarc = function(_, alias)
      local byId = assert(members[alias], "fixture has no archive " .. alias)
      return {
        memberCount = function()
          return 965
        end,
        readMember = function(_, memberId)
          -- Every catalog map names its own event and matrix members; the
          -- shared 1x1 fixture serves the same bytes for any requested id so
          -- any map compiles. The land member id, conversely, is the one the
          -- matrix references and must exist exactly.
          if alias == "zone_events" then
            return assert(members.zone_events[opts.eventMemberId or FieldMapDataFixture.EVENT_MEMBER_ID])
          end
          if alias == "map_matrices" then
            return assert(members.map_matrices[opts.matrixMemberId or FieldMapDataFixture.MATRIX_MEMBER_ID])
          end
          if alias == "field_script_headers" then
            return assert(members.field_script_headers[opts.scriptHeaderMemberId or 618])
          end
          local bytes = byId[memberId]
          assert(bytes, string.format("fixture %s has no member %d", alias, memberId))
          return bytes
        end,
      }
    end,
    read = function(_, fileId)
      return "synthetic-" .. tostring(fileId)
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return romFs
end

return FieldMapDataFixture
