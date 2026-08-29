-- ROM conformance facts for the production navigation corridor. Targets are
-- selected from normalized generated data in a stable order, never from
-- hand-measured presentation coordinates.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local NavigationFacts = require("tests.rom.support.NavigationFacts")

local T = {}

function T.discovers_stable_new_bark_route_29_targets(romFs, versionId)
  local facts = NavigationFacts.discover(CacheFs.forVersion(versionId), romFs)
  Assert.equal(facts.newBark.mapId, 60)
  Assert.equal(facts.route29.mapId, 33)
  Assert.equal(facts.newBark.matrixX, 21)
  Assert.equal(facts.newBark.matrixZ, 12)
  Assert.equal(facts.water.direction ~= nil, true)
  Assert.equal(facts.grass.fieldX == math.floor(facts.grass.fieldX), true)
  Assert.equal(facts.ledge.direction ~= nil, true)
  Assert.equal(
    math.abs(math.floor(facts.far.fieldX / 32) - facts.newBark.matrixX) >= 2
      or math.abs(math.floor(facts.far.fieldZ / 32) - facts.newBark.matrixZ) >= 2,
    true
  )
  Assert.equal(facts.buildingWarp.destinationMapId ~= facts.newBark.mapId, true)
end

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
return suite
