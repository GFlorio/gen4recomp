-- Test helper: a synthetic HGSS-shaped NDS and a full extraction of it into an
-- in-memory cache. The tree carries the four required NARC paths (personal,
-- moves, messages, map_matrices) plus the readiness sound file, one arm9
-- overlay (fileId 0), and one unmapped file (fileId 1), so both the extractor
-- and RomFs can be exercised end to end without a real ROM.
--
-- Resulting FAT layout: 0 overlay9, 1 unmapped, 2 a/0/0/2, 3 a/0/1/1,
-- 4 a/0/2/7, 5 a/0/4/1, 6 data/sound/gs_sound_data.sdat (7 entries total).

local NdsBuilder = require("tests.support.NdsBuilder")
local NarcBuilder = require("tests.support.NarcBuilder")
local NdsRom = require("libs.rom.src.NdsRom")
local RomSource = require("libs.rom.src.RomSource")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local GameVersion = require("libs.rom.src.GameVersion")
local RomExtractor = require("libs.rom.src.RomExtractor")
local Hgss = require("data.manifests.hgss")

local DumpFixture = {}

local function u8(v) return string.char(v % 256) end
local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end

-- A valid map-matrix member 0: 2x2, no optional sections, four model ids.
function DumpFixture.mapMatrixMember()
  local parts = { u8(2), u8(2), u8(0), u8(0), u8(2), "MM" }
  for _, id in ipairs({ 40, 41, 42, 43 }) do parts[#parts + 1] = u16(id) end
  return table.concat(parts)
end

-- Fresh spec each call so tests can mutate it without cross-contamination.
function DumpFixture.spec()
  return {
    gameCode = "IPKE",
    title = "TESTHG",
    overlays9 = { "OVERLAY0-DATA" },
    unmapped = { "UNMAPPED-DATA" },
    tree = {
      files = {},
      dirs = {
        { name = "a", files = {}, dirs = {
          { name = "0", files = {}, dirs = {
            { name = "0", files = { { name = "2", content = NarcBuilder.build({ "P0", "P1" }) } } },
            { name = "1", files = { { name = "1", content = NarcBuilder.build({ "M0" }) } } },
            { name = "2", files = { { name = "7", content = NarcBuilder.build({ "MSG0" }) } } },
            { name = "4", files = { { name = "1", content = NarcBuilder.build({ DumpFixture.mapMatrixMember() }) } } },
          } },
        } },
        { name = "data", files = {}, dirs = {
          { name = "sound", files = { { name = "gs_sound_data.sdat", content = "SDAT-STUB" } } },
        } },
      },
    },
  }
end

-- Open the given spec as an NdsRom, injecting a version catalog that accepts
-- exactly this synthetic ROM under game code IPKE.
function DumpFixture.openRom(spec)
  local data = NdsBuilder.build(spec or DumpFixture.spec())
  local info = { sha1 = RomSource.fromString(data):sha1(), gameCode = "IPKE", expectedSize = #data }
  local versions = {
    forSha1 = function(h) return h == info.sha1 and info or nil end,
    forGameCode = function(c) return c == "IPKE" and info or nil end,
  }
  return NdsRom.open(RomSource.fromString(data), versions)
end

-- Run a full extraction into a fresh (or supplied) FakeCache-backed cache. The
-- marker uses the real canonical sha1 (via GameVersion.info) so RomImporter and
-- RomFs accept the dump, exactly as production would after SHA-1 validation.
-- opts = { spec=, versionId=, backend=, progress= }.
function DumpFixture.extract(opts)
  opts = opts or {}
  local versionId = opts.versionId or "heartgold"
  local backend = opts.backend or FakeCache.new()
  local rom, romErr = DumpFixture.openRom(opts.spec)
  assert(rom, "fixture ROM failed to open: " .. tostring(romErr))
  local cache = CacheFs.forVersion(versionId, backend)
  local extractor = RomExtractor.new(rom, GameVersion.info(versionId), cache, Hgss, opts.progress)
  local report, err = extractor:run()
  return { cache = cache, backend = backend, report = report, err = err, rom = rom, versionId = versionId }
end

return DumpFixture
