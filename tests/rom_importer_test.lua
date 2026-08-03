local Assert = require("tests.support.Assert")
local Errors = require("src.import.Errors")
local RomImporter = require("src.import.RomImporter")
local RomSource = require("src.import.RomSource")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")
local CacheFs = require("src.import.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local HG = "heartgold/"

-- Build a synthetic HGSS ROM plus a version catalog that accepts exactly it under
-- the real "heartgold" identity, so the importer's marker/readiness logic aligns.
-- `now` is static, which disables yielding: a single update() runs to completion.
local function harness(spec)
  local data = NdsBuilder.build(spec or DumpFixture.spec())
  local sha1 = RomSource.fromString(data):sha1()
  local info = {
    id = "heartgold", label = "HeartGold", displayName = "Pokemon HeartGold",
    sha1 = sha1, gameCode = "IPKE", expectedSize = #data, cachePrefix = "heartgold/",
  }
  local versions = {
    info = function(id) return id == "heartgold" and info or nil end,
    forSha1 = function(h) return h == sha1 and info or nil end,
    forGameCode = function(c) return c == "IPKE" and info or nil end,
  }
  local backend = FakeCache.new()
  local events = {}
  local importer = RomImporter.new({
    versions = versions,
    now = function() return 0 end,
    cacheFactory = function(id) return CacheFs.forVersion(id, backend) end,
    onComplete = function(id) events[#events + 1] = id end,
  })
  return { data = data, info = info, versions = versions, backend = backend,
    importer = importer, events = events }
end

-- Drive update() until the importer reaches a terminal state (or a step cap).
local function runToTerminal(importer)
  for _ = 1, 10000 do
    importer:update()
    if importer.state == "complete" or importer.state == "error" then return end
  end
  error("importer did not terminate")
end

-- An ever-advancing clock forces a yield at every progress tick, exercising the
-- coroutine-yield-across-pcall path the real import relies on under LuaJIT.
function T.yields_and_still_completes_across_pcall()
  local h = harness()
  local t = 0
  local importer = RomImporter.new({
    versions = h.versions,
    now = function() t = t + 1 return t end,
    cacheFactory = function(id) return CacheFs.forVersion(id, h.backend) end,
  })
  importer:startSource(RomSource.fromString(h.data))
  local ticks = 0
  for _ = 1, 10000 do
    importer:update()
    ticks = ticks + 1
    if importer.state == "complete" or importer.state == "error" then break end
  end
  Assert.equal(importer.state, "complete")
  Assert.isTrue(ticks > 1, "expected the import to span multiple update() slices")
end

function T.imports_synthetic_rom_to_completion()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data, "hg.nds"))
  runToTerminal(h.importer)
  Assert.equal(h.importer.state, "complete")
  Assert.equal(h.importer:status().versionId, "heartgold")
  Assert.equal(h.importer.progress, 1)
  Assert.isTrue(RomImporter.isReady("heartgold", CacheFs.forVersion("heartgold", h.backend), h.versions))
  Assert.equal(h.events[1], "heartgold")
end

-- Validation (SHA-1/header) must fully precede any cache write (E8-S1).
function T.validation_precedes_cache_cleanup()
  local h = harness()
  -- Pre-seed a marker and a stray file; an unknown ROM must leave them intact.
  h.backend.files[HG .. "rom-dump.complete"] = "STALE"
  h.backend.files[HG .. "stray"] = "KEEP"
  -- A version catalog that recognizes nothing => NdsRom.open rejects by SHA-1.
  local blind = { info = function() end, forSha1 = function() end, forGameCode = function() end }
  local importer = RomImporter.new({
    versions = blind,
    now = function() return 0 end,
    cacheFactory = function(id) return CacheFs.forVersion(id, h.backend) end,
  })
  importer:startSource(RomSource.fromString(h.data))
  runToTerminal(importer)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "NDS_UNKNOWN_ROM")
  Assert.equal(h.backend.files[HG .. "rom-dump.complete"], "STALE")
  Assert.equal(h.backend.files[HG .. "stray"], "KEEP")
end

-- A dropped non-.nds file is rejected with a friendly error before any read,
-- leaving caches untouched (E8-S3).
function T.rejects_non_nds_drop()
  local importer = RomImporter.new({ now = function() return 0 end })
  local stub = { getFilename = function() return "photo.png" end }
  importer:filedropped(stub)
  Assert.equal(importer.state, "error")
  Assert.equal(importer:status().errorCode, "IMPORT_NOT_NDS")
end

function T.releases_rom_on_completion()
  local h = harness()
  local source = RomSource.fromString(h.data)
  h.importer:startSource(source)
  runToTerminal(h.importer)
  -- Source is released: further reads fail predictably.
  local bytes, err = source:read(0, 4)
  Assert.isNil(bytes)
  Assert.equal(err.code, "ROM_RELEASED")
end

function T.progress_is_monotonic()
  local h = harness()
  local last = -1
  -- Wrap onProgress by observing status each update.
  h.importer:startSource(RomSource.fromString(h.data))
  for _ = 1, 10000 do
    h.importer:update()
    local p = h.importer.progress or 0
    Assert.isTrue(p >= last, "progress regressed: " .. p .. " < " .. last)
    last = p
    if h.importer.state == "complete" or h.importer.state == "error" then break end
  end
  Assert.equal(h.importer.state, "complete")
  Assert.equal(last, 1)
end

-- An explicitly supplied ROM is always dumped fresh: re-importing a ready
-- version re-extracts rather than skipping.
function T.reimport_always_extracts()
  local h = harness()
  h.importer:startSource(RomSource.fromString(h.data))
  runToTerminal(h.importer)
  Assert.notNil(h.importer:status().report)

  local again = RomImporter.new({
    versions = h.versions,
    now = function() return 0 end,
    cacheFactory = function(id) return CacheFs.forVersion(id, h.backend) end,
  })
  again:startSource(RomSource.fromString(h.data))
  runToTerminal(again)
  Assert.equal(again.state, "complete")
  Assert.notNil(again:status().report, "a fresh extraction is always performed")
end

return T
