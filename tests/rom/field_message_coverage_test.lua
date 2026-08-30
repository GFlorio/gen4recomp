-- Real-dump coverage for source-reachable message banks through the compiled
-- cache and the lazy runtime provider.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local FieldMessageProvider = require("libs.hgss.src.field.FieldMessageProvider")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local RomSuite = require("tests.rom.support.RomSuite")

local ROUTE_29_BANK = 373

local suite = RomSuite.fromFacts({
  route_29_bank_is_ready_and_lazily_served = function(romFs, version)
    local route29 = MapCatalog.require("MAP_ROUTE_29")
    Assert.equal(route29.messageMemberId, ROUTE_29_BANK)

    local bundle = assert(FieldMessageCompiler.compile(romFs --[[@as RomFs]]))
    local occurrences = 0
    for _, bankId in ipairs(bundle.index.bankIds) do
      if bankId == ROUTE_29_BANK then
        occurrences = occurrences + 1
      end
    end
    Assert.equal(occurrences, 1, "Route 29's message bank must be indexed exactly once")

    local cache = CacheFs.forVersion(version)
    Assert.isTrue(
      FieldMessageCache.isReady(cache, bundle.marker),
      "the generated message cache must contain every selected bank"
    )
    local provider = assert(FieldMessageProvider.new(cache))
    local bank, err = provider:acquireBank(ROUTE_29_BANK)
    Assert.notNil(bank, err and err.message or "Route 29's message bank must be available")
    Assert.equal(assert(bank).schema, FieldMessageCache.SCHEMA)
    Assert.equal(assert(bank).bankId, ROUTE_29_BANK)
    provider:releaseBank(ROUTE_29_BANK)
  end,
})

suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "field", "messages", "coverage" }

return suite
