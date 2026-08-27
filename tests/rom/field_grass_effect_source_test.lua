-- ROM-conformance coverage for the two source selector streams and the
-- normalized field-effect definitions produced from them.

local Assert = require("tests.support.Assert")
local Contract = require("libs.assets.src.DerivedAssetContract")
local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local FieldEffects = require("romdump.src.config.FieldEffects")
local FieldEffectPatternAnimation = require("romdump.src.digest.FieldEffectPatternAnimation")
local FieldEntranceIndicatorCompiler = require("romdump.src.digest.FieldEntranceIndicatorCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local RomSuite = require("tests.rom.support.RomSuite")

local SOURCES = {
  { kind = "tall_grass", renderer = 8, modelMember = 126, animationMember = 140 },
  { kind = "very_tall_grass", renderer = 12, modelMember = 122, animationMember = 146 },
}

local function selectorB(bytes, keyCount, index)
  local offset = 4 + keyCount * 3
  return assert(bytes:byte(offset + index + 1), "source selector is truncated")
end

local function cacheFor(bundle)
  return {
    read = function(_, path)
      if path == FieldEffectAssetCache.markerPath() then
        return bundle.marker
      end
      return nil
    end,
    loadLua = function(_, path)
      if path == FieldEffectAssetCache.indexPath() then
        return bundle.index
      end
      for _, source in ipairs(SOURCES) do
        if path == FieldEffectAssetCache.definitionPath(source.kind) then
          return bundle.effects[source.kind]
        end
      end
      if path == FieldEffectAssetCache.definitionPath("warp_entrance") then
        return bundle.effects.warp_entrance
      end
      error("unexpected field-effect cache path " .. path)
    end,
    exists = function()
      return true
    end,
  }
end

local function assertSource(compiled, source, animationNarc)
  local definition = assert(compiled.effects[source.kind])
  local clip = assert(assert(definition.model.animations)[1])
  local payload = assert(clip.compiled)
  local target = assert(payload.targets[1])
  local raw = assert(animationNarc:readMember(source.animationMember))
  local decoded = assert(FieldEffectPatternAnimation.decode(raw, {
    alias = FieldEffects.animationArchive.alias,
    memberId = source.animationMember,
  }))

  Assert.equal(#target.keys, #decoded.keys)
  for index, expected in ipairs(decoded.keys) do
    local actual = target.keys[index]
    Assert.equal(actual.frame, expected.frame)
    Assert.equal(actual.texIdx, expected.texIdx)
    Assert.equal(actual.plttIdx, selectorB(raw, #decoded.keys, index - 1))
    Assert.isTrue(actual.texIdx < #payload.textureNames, "source texture selector must be in range")
    Assert.isTrue(actual.plttIdx < #payload.paletteNames, "source palette selector must be in range")
  end
  Assert.equal(clip.source.archive, FieldEffects.animationArchive.alias)
  Assert.equal(clip.source.memberId, source.animationMember)
  Assert.equal(clip.source.sha1, Hashing.sha1hex(raw))
  Assert.equal(FieldEffects.effects[source.kind].renderer, source.renderer)
  Assert.equal(FieldEffects.effects[source.kind].modelMembers[1], source.modelMember)
  Assert.equal(FieldEffects.effects[source.kind].animationMembers[1], source.animationMember)
  Assert.isNil(definition.animationSourceSha1)
  Assert.isNil(definition.source)
  Assert.equal(definition.lifecycle.holdFrame, 12)
  Assert.isTrue(definition.lifecycle.holdUntilOwnerMoves)
  Assert.equal(definition.placementOffset.x, 0)
  Assert.equal(definition.placementOffset.y, 0)
  Assert.equal(definition.placementOffset.z, 0.625)
end

local suite = RomSuite.fromFacts({
  ["compiles both source grass definitions without selector inference"] = function(romFs)
    Assert.equal(Contract.fieldEffects.cacheFormat, "field-effect-cache-v6")
    Assert.equal(FieldEffectAssetCache.FORMAT, "field-effect-cache-v6")

    local animationNarc = assert(romFs:openNarc(FieldEffects.animationArchive.alias))
    local compiled = FieldEntranceIndicatorCompiler.compile(romFs)
    for _, source in ipairs(SOURCES) do
      assertSource(compiled, source, animationNarc)
    end

    Assert.isTrue(
      FieldEffectAssetCache.isReady(cacheFor(compiled), compiled.marker),
      "the normalized source bundle must satisfy the strict field-effect cache contract"
    )
  end,
})
suite.metadata.capabilities = { "rom_dump", "derived_cache" }
suite.metadata.tags = { "field", "grass", "source" }
return suite
