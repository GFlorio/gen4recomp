local Assert = require("tests.support.Assert")
local RomSource = require("libs.rom.src.RomSource")
local ZipBuilder = require("tests.support.ZipBuilder")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")

-- SHA-1("abc") — the canonical test vector.
local ABC_SHA1 = "a9993e364706816aba3e25717850c26c9cd0d89d"

local T = {}

-- A version catalog that recognizes exactly the given SHA-1 (as DumpFixture does).
local function versionsFor(sha1)
  return { forSha1 = function(h) return h == sha1 and {} or nil end }
end

function T.from_string_reports_size_and_name()
  local s = RomSource.fromString("abcdef", "sample.nds")
  Assert.equal(s:size(), 6)
  Assert.equal(s:displayName(), "sample.nds")
end

function T.read_is_zero_based()
  local s = RomSource.fromString("abcdef")
  Assert.equal(s:read(0, 3), "abc")
  Assert.equal(s:read(3, 3), "def")
end

function T.read_out_of_range_returns_nil_err()
  local s = RomSource.fromString("abc")
  local data, err = s:read(2, 5)
  Assert.isNil(data)
  Assert.notNil(err)
  local d2, e2 = s:read(-1, 1)
  Assert.isNil(d2)
  Assert.notNil(e2)
end

function T.sha1_is_lowercase_hex_and_cached()
  local s = RomSource.fromString("abc")
  local first = s:sha1()
  Assert.equal(first, ABC_SHA1)
  Assert.equal(s:sha1(), first)
end

function T.release_is_idempotent_and_frees_reads()
  local s = RomSource.fromString("abc")
  s:release()
  s:release()
  local data, err = s:read(0, 1)
  Assert.isNil(data)
  Assert.notNil(err)
end

function T.from_path_reads_file_bytes()
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  f:write("abc")
  f:close()

  local s, err = RomSource.fromPath(path)
  Assert.notNil(s, err and tostring(err))
  Assert.equal(s:size(), 3)
  Assert.equal(s:read(0, 3), "abc")
  Assert.equal(s:sha1(), ABC_SHA1)
  os.remove(path)
end

function T.from_path_missing_returns_nil_err()
  local s, err = RomSource.fromPath("/no/such/file.nds")
  Assert.isNil(s)
  Assert.notNil(err)
end

-- Walks a zip (including nested dirs), skips non-.nds junk, and returns the
-- compatible ROM's bytes.
function T.from_zip_finds_compatible_nds()
  local nds = NdsBuilder.build(DumpFixture.spec())
  local sha1 = RomSource.fromString(nds):sha1()
  local zip = ZipBuilder.build({
    { name = "Vimm's Lair.txt", data = "junk" },
    { name = "roms/Pokemon - HeartGold (USA).nds", data = nds },
  })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor(sha1))
  Assert.notNil(s, err and tostring(err))
  Assert.equal(s:size(), #nds)
  Assert.equal(s:sha1(), sha1)
  Assert.isTrue(s:read(0, #nds) == nds, "zip-extracted bytes must match the .nds")
end

-- When several .nds are present, the SHA-1-supported one wins.
function T.from_zip_prefers_supported_nds()
  local good = NdsBuilder.build(DumpFixture.spec())
  local goodSha = RomSource.fromString(good):sha1()
  local zip = ZipBuilder.build({
    { name = "patched.nds", data = "not a real rom" },
    { name = "good.nds", data = good },
  })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor(goodSha)))
  Assert.equal(s:sha1(), goodSha)
end

-- No .nds inside → a structured error, not a crash.
function T.from_zip_without_nds_errors()
  local zip = ZipBuilder.build({ { name = "a.txt", data = "x" }, { name = "b.sav", data = "y" } })
  local s, err = RomSource.fromZipData(zip, "rom.zip", versionsFor("none"))
  Assert.isNil(s)
  Assert.equal(err.code, "ZIP_NO_NDS")
end

-- A single unsupported .nds is still returned so NdsRom.open can report its hash.
function T.from_zip_falls_back_to_first_nds()
  local zip = ZipBuilder.build({ { name = "only.nds", data = "unsupported bytes" } })
  local s = assert(RomSource.fromZipData(zip, "rom.zip", versionsFor("none")))
  Assert.equal(s:read(0, 17), "unsupported bytes")
end

-- Dropped files arrive as LÖVE File objects; verify the wiring against a stub.
function T.from_dropped_file_reads_contents()
  local stub = {
    open = function() return true end,
    read = function() return "abc" end,
    close = function() return true end,
    getFilename = function() return "dropped.nds" end,
  }
  local s = RomSource.fromDroppedFile(stub)
  Assert.equal(s:displayName(), "dropped.nds")
  Assert.equal(s:read(0, 3), "abc")
end

return T
