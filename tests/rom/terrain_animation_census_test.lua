-- ROM-conformance census for the terrain texture-animation archive
-- (`data/fldtanime.narc`, dump alias `field_texture_animations`): the retail
-- archive has nine table records and ten members, every schedule index used
-- by a record has a compatible replacement-dictionary entry, and every
-- texture-swap material in the generated corpus carries the retail live
-- schedule -- same step count, same duration sequence -- with present
-- replacement images, so the producer compiled every referenced frame
-- against a matching map texture pack when the derived cache was built. One
-- pass over the whole ready corpus per version.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomFs = require("romdump.src.source.RomFs")
local FieldTextureAnimation = require("romdump.src.digest.FieldTextureAnimation")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local MapAssetCache = require("libs.assets.src.MapAssetCache")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "terrain", "census" },
  },
  tests = {},
}

-- The known retail archive shape. These values are expected output of the
-- ROM inputs and belong in a ROM census test, not production constants.
local RETAIL_MEMBER_COUNT = 10
local RETAIL_RECORD_COUNT = 9
local RETAIL_RECORD_NAMES = {
  "sea_on",
  "swave_p",
  "swave_un",
  "sea_rock",
  "sea_rock_m",
  "flower01",
  "flower02",
  "dsea_on",
  "r_sea_rock",
}

local function swapMaterials(scene)
  local out = {}
  for _, m in ipairs(scene.materials or {}) do
    if m.textureSwap then
      out[#out + 1] = m
    end
  end
  for _, neighbor in ipairs(scene.neighbors or {}) do
    for _, m in ipairs(neighbor.materials or {}) do
      if m.textureSwap then
        out[#out + 1] = m
      end
    end
  end
  return out
end

-- The retail live schedule's durations, in order.
local function retailDurations(record)
  local out = {}
  for _, pair in ipairs(record.timeline) do
    out[#out + 1] = pair.durationTicks
  end
  return out
end

-- A generated swap's step durations, in order.
local function stepDurations(swap)
  local out = {}
  for _, step in ipairs(swap.steps) do
    out[#out + 1] = step.durationTicks
  end
  return out
end

function T.tests.retail_archive_and_corpus_swaps_compile(context)
  local runnable = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cache = CacheFs.forVersion(versionId)
      if cache:exists("data/generated/maps", "directory") then
        runnable[#runnable + 1] = { versionId = versionId, cache = cache }
      end
    end
  end
  if #runnable == 0 then
    context:skip("no ready version with a derived cache")
  end

  for _, entry in ipairs(runnable) do
    local versionId, cache = entry.versionId, entry.cache
    local romFs, openErr = RomFs.open(versionId)
    assert(romFs, versionId .. ": cannot open the dump: " .. tostring(openErr))

    -- Retail archive census: one table member plus one replacement member
    -- per record, and every used schedule index resolvable in its
    -- replacement TEX0 dictionary.
    local narc = assert(romFs:openNarc("field_texture_animations"), versionId .. ": archive opens")
    Assert.equal(narc:memberCount(), RETAIL_MEMBER_COUNT, versionId .. ": the retail archive has ten members")
    local records, parseErr = FieldTextureAnimation.parse(
      assert(narc:readMember(0)),
      { mapId = -1, alias = "field_texture_animations", memberId = 0 }
    )
    assert(records, versionId .. ": member 0 parses: " .. tostring(parseErr))
    Assert.equal(#records, RETAIL_RECORD_COUNT, versionId .. ": nine table records")
    local names = {}
    for _, rec in ipairs(records) do
      names[#names + 1] = rec.name
    end
    Assert.deepEqual(names, RETAIL_RECORD_NAMES, versionId .. ": known retail record names in table order")

    local recordByName = {}
    for _, rec in ipairs(records) do
      recordByName[rec.name] = rec
      local packBytes = assert(
        narc:readMember(rec.index + 1),
        versionId .. ": replacement member " .. (rec.index + 1) .. " of " .. rec.name
      )
      local pack = assert(Nsbtx.decode(packBytes), versionId .. ": replacement member of " .. rec.name .. " is BTX0")
      for _, pair in ipairs(rec.timeline) do
        Assert.isTrue(
          pair.textureIndex < #pack.textures,
          versionId
            .. ": "
            .. rec.name
            .. " schedule index "
            .. pair.textureIndex
            .. " has a replacement dictionary entry (size "
            .. #pack.textures
            .. ")"
        )
      end
    end

    -- Corpus census over the generated cache: every compiled texture-swap
    -- material matched a retail record by texture name, carries the retail
    -- live schedule unchanged (same step count, same duration sequence), and
    -- references only replacement images that exist -- the compile itself
    -- succeeded against the matching map texture pack when the cache was
    -- built. The base material's image and the schedule's first step are
    -- independent assets: no equality between them is implied or asserted.
    local world = assert(cache:loadLua(MapAssetCache.worldPath()), versionId .. ": world manifest is loadable")
    assert(type(world.maps) == "table", versionId .. ": world manifest carries the map list")

    local sceneCount, swapMaps, swapCount = 0, 0, 0
    local used = {}
    for _, map in ipairs(world.maps) do
      local dir = MapAssetCache.mapDir(map.id)
      if cache:exists(dir .. "/complete") then
        sceneCount = sceneCount + 1
        local scene = assert(cache:loadLua(dir .. "/scene.lua"), "scene " .. map.id .. " is loadable")
        local swaps = swapMaterials(scene)
        if #swaps > 0 then
          swapMaps = swapMaps + 1
        end
        for _, m in ipairs(swaps) do
          swapCount = swapCount + 1
          local swap = m.textureSwap
          local record = recordByName[swap.name]
          Assert.notNil(
            record,
            versionId .. ": swap name " .. swap.name .. " matches a retail record (map " .. map.id .. ")"
          )
          Assert.isTrue(
            type(m.texture) == "string",
            versionId .. ": map " .. map.id .. " " .. swap.name .. " has a base texture"
          )
          Assert.equal(
            #swap.steps,
            #record.timeline,
            versionId .. ": map " .. map.id .. " " .. swap.name .. " step count equals the retail live schedule"
          )
          Assert.deepEqual(
            stepDurations(swap),
            retailDurations(record),
            versionId .. ": map " .. map.id .. " " .. swap.name .. " carries the retail duration sequence"
          )
          for _, step in ipairs(swap.steps) do
            Assert.isTrue(
              cache:exists(step.texture),
              versionId .. ": replacement frame exists in the cache: " .. step.texture .. " (map " .. map.id .. ")"
            )
          end
          used[swap.name] = true
        end
      end
    end

    -- Coverage: the census really spanned the corpus, and every retail
    -- record participates in at least one generated map.
    Assert.isTrue(sceneCount > 0, versionId .. ": the census reached ready maps")
    Assert.isTrue(swapMaps > 0, versionId .. ": the corpus exercises texture swaps")
    Assert.isTrue(swapCount > 0, versionId .. ": the corpus carries swap materials")
    for _, name in ipairs(RETAIL_RECORD_NAMES) do
      Assert.isTrue(
        used[name] == true,
        versionId .. ": retail record " .. name .. " is used by at least one corpus map"
      )
    end

    romFs:close()
  end
end

return T
