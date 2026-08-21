-- ROM-conformance facts for the source-derived Professor Oak/profile visual
-- class. Physical source identities belong to provenance; runtime records stay
-- semantic and contain only the native frame/payload data the presentation layer needs.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function introCache()
  local ok, cache = pcall(require, "libs.assets.src.IntroAssetCache")
  if not ok then
    error("the intro visual cache contract is missing: " .. tostring(cache), 0)
  end
  return cache
end

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCompiler")
  if not ok then
    error("the ROM-derived intro compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function hasPhysicalLookup(value)
  if type(value) ~= "table" then
    return false
  end
  for key, nested in pairs(value) do
    if key == "narcId" or key == "memberId" or key == "archive" or key == "sourceMember" then
      return true
    end
    if hasPhysicalLookup(nested) then
      return true
    end
  end
  return false
end

local function payloadBytes(bundle)
  local paths = {}
  for path in pairs(bundle.assets) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local bytes = {}
  for _, path in ipairs(paths) do
    bytes[#bytes + 1] = path .. "\0" .. bundle.assets[path]
  end
  return table.concat(bytes, "\0")
end

function T.semantic_manifest_keeps_source_identity_in_provenance_only(romFs)
  local bundle = assert(compiler().compile(romFs))
  local cache = introCache()
  Assert.equal(bundle.manifest.schema, cache.SCHEMA)
  Assert.isTrue(type(bundle.dependencies) == "table", "the generated class records provenance")
  Assert.isTrue(hasPhysicalLookup(bundle.dependencies), "provenance identifies the source members")
  Assert.isFalse(hasPhysicalLookup(bundle.manifest), "runtime manifest does not expose physical source lookups")
  for id, record in pairs(bundle.manifest.assets) do
    Assert.equal(type(id), "string", "runtime visual identity is semantic")
    Assert.isNil(record.narcId, id .. " does not carry a NARC identity")
    Assert.isNil(record.memberId, id .. " does not carry a member identity")
    Assert.isNil(record.archive, id .. " does not carry an archive identity")
  end
end

function T.each_ready_source_version_emits_the_closed_core_inventory(romFs)
  local first = assert(compiler().compile(romFs))
  local second = assert(compiler().compile(romFs))
  Assert.deepEqual(first.manifest, second.manifest, "identical source bytes produce identical semantic output")
  Assert.deepEqual(first.dependencies, second.dependencies, "identical source bytes produce identical provenance")
  Assert.equal(payloadBytes(first), payloadBytes(second), "identical source bytes produce identical payloads")
  Assert.equal(first.manifest.reference.filter, "nearest")
  local ids = {}
  for id in pairs(first.manifest.assets) do
    ids[id] = true
    Assert.isFalse(id:find("tutorial", 1, true) ~= nil, "tutorial resources are excluded")
  end
  for _, id in ipairs({
    "background",
    "oak",
    "marill",
    "gender.male",
    "gender.female",
    "gender.indicator",
    "shrink.male",
    "shrink.female",
  }) do
    Assert.isTrue(ids[id], "required semantic resource " .. id .. " is present")
  end
end

return RomSuite.fromFacts(T)
