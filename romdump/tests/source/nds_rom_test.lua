local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local NdsRom = require("romdump.src.source.NdsRom")
local RomSource = require("romdump.src.source.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")

local T = {}

---@class TestNdsRom
---@field header fun(self: TestNdsRom): table
---@field fatCount fun(self: TestNdsRom): integer
---@field readFatFile fun(self: TestNdsRom, fileId: integer): string
---@field nitroFs fun(self: TestNdsRom): table
---@field arm9Overlays fun(self: TestNdsRom): table[]
---@field arm7Overlays fun(self: TestNdsRom): table[]
---@field fileMap fun(self: TestNdsRom): table
---@field read fun(self: TestNdsRom, offset: integer, size: integer): string

-- Canonical fixture: one arm9 overlay (fileId 0), one unmapped file (fileId 1),
-- then a nested NitroFS tree (fileIds 2..4).
local FIXTURE = {
  gameCode = "IPKE",
  title = "TESTHG",
  overlays9 = { "OVERLAY0-DATA" },
  unmapped = { "UNMAPPED-DATA" },
  tree = {
    files = { { name = "root.bin", content = "ROOT" } },
    dirs = {
      {
        name = "folder",
        files = { { name = "a.bin", content = "AAAA" } },
        dirs = {
          { name = "nested", files = { { name = "b.bin", content = "BB" } } },
        },
      },
    },
  },
}

-- An injected version catalog that recognizes exactly `data` under `gameCode`.
local function matchingVersions(data, gameCode)
  local info = { sha1 = RomSource.fromString(data):sha1(), gameCode = gameCode, expectedSize = #data }
  return {
    forSha1 = function(h)
      return h == info.sha1 and info or nil
    end,
    forGameCode = function(c)
      return c == gameCode and info or nil
    end,
  }
end

-- FIXTURE with an injected corruption flag.
local function corruptFixture(corrupt)
  local spec = {}
  for k, v in pairs(FIXTURE) do
    spec[k] = v
  end
  spec.corrupt = corrupt
  return spec
end

---@param spec table?
---@return TestNdsRom?
---@return Errors.Error?
local function openFixture(spec)
  spec = spec or FIXTURE
  local data = NdsBuilder.build(spec)
  local rom, err = NdsRom.open(RomSource.fromString(data), matchingVersions(data, spec.gameCode or "IPKE"))
  local typedRom = rom --[[@as TestNdsRom?]]
  return typedRom, err
end

---@param rom TestNdsRom?
---@param err Errors.Error?
---@return TestNdsRom
local function assertOk(rom, err)
  Assert.notNil(rom, "expected NdsRom, got error: " .. Errors.format(err))
  return assert(rom)
end

function T.parses_header_fields()
  local rom = assertOk(openFixture())
  local h = rom:header()
  Assert.equal(h.gameCode, "IPKE")
  Assert.equal(h.title, "TESTHG")
  Assert.equal(h.makerCode, "01")
  Assert.equal(h.headerSize, 0x4000)
  Assert.isTrue(h.fat.offset > 0)
  Assert.isTrue(h.fnt.size > 0)
end

function T.exposes_zero_based_fat_files()
  local rom = assertOk(openFixture())
  Assert.equal(rom:fatCount(), 5)
  Assert.equal(rom:readFatFile(0), "OVERLAY0-DATA")
  Assert.equal(rom:readFatFile(1), "UNMAPPED-DATA")
  Assert.equal(rom:readFatFile(2), "ROOT")
  Assert.equal(rom:readFatFile(4), "BB")
end

function T.parses_nitrofs_and_overlays()
  local rom = assertOk(openFixture())
  Assert.equal(rom:nitroFs().byFileId[2], "root.bin")
  Assert.equal(rom:nitroFs().byPath["folder/nested/b.bin"], 4)
  Assert.equal(#rom:arm9Overlays(), 1)
  Assert.equal(rom:arm9Overlays()[1].fileId, 0)
  Assert.equal(#rom:arm7Overlays(), 0)
end

function T.assigns_one_destination_to_every_fat_entry()
  local rom = assertOk(openFixture())
  local map = rom:fileMap()
  Assert.equal(map[0].kind, "overlay9")
  Assert.equal(map[0].path, "system/overlay9/overlay_0.bin")
  Assert.equal(map[0].overlayId, 0)
  Assert.equal(map[1].kind, "unmapped")
  Assert.equal(map[1].path, "system/unmapped/file_1.bin")
  Assert.equal(map[2].kind, "nitrofs")
  Assert.equal(map[2].path, "romfs/root.bin")
  Assert.equal(map[2].sourcePath, "root.bin")
  Assert.equal(map[4].path, "romfs/folder/nested/b.bin")

  -- Exactly one destination per FAT entry, no duplicates.
  local seen, count = {}, 0
  for id = 0, rom:fatCount() - 1 do
    Assert.notNil(map[id], "missing assignment for fileId " .. id)
    Assert.isNil(seen[map[id].path], "duplicate destination " .. tostring(map[id].path))
    seen[map[id].path] = true
    count = count + 1
  end
  Assert.equal(count, rom:fatCount())
end

function T.file_map_offsets_match_fat()
  local rom = assertOk(openFixture())
  local map = rom:fileMap()
  Assert.equal(map[2].size, 4) -- "ROOT"
  Assert.equal(rom:read(map[2].offset, map[2].size), "ROOT")
end

local function throwsOpenCode(code, source, versions)
  local rom, err = NdsRom.open(source, versions)
  Assert.isNil(rom, "expected open to fail")
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(assert(err).code, code)
end

function T.rejects_short_header()
  throwsOpenCode("NDS_TOO_SMALL", RomSource.fromString("short"), {
    forSha1 = function() end,
    forGameCode = function() end,
  })
end

function T.rejects_unknown_sha1()
  local data = NdsBuilder.build(FIXTURE)
  local versions = {
    forSha1 = function()
      return nil
    end,
    forGameCode = function()
      return nil
    end,
  }
  throwsOpenCode("NDS_UNKNOWN_ROM", RomSource.fromString(data), versions)
end

function T.rejects_game_code_mismatch()
  -- SHA-1 matches, but the matched version expects a different game code.
  local data = NdsBuilder.build(FIXTURE)
  throwsOpenCode("NDS_GAME_CODE_MISMATCH", RomSource.fromString(data), matchingVersions(data, "IPGE"))
end

function T.rejects_fat_size_not_divisible_by_8()
  local data = NdsBuilder.build(corruptFixture({ fatNotDiv8 = true }))
  throwsOpenCode("NDS_FAT_SIZE_INVALID", RomSource.fromString(data), matchingVersions(data, "IPKE"))
end

function T.rejects_out_of_range_section()
  local data = NdsBuilder.build(corruptFixture({ sectionOutOfRange = true }))
  throwsOpenCode("NDS_SECTION_OUT_OF_RANGE", RomSource.fromString(data), matchingVersions(data, "IPKE"))
end

return { tests = T }
