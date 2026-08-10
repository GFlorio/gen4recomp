-- Private target test: the field-actor graphics table, resource bundles, and
-- compiled visuals against a real HGSS dump. It asserts only structural facts --
-- counts, offsets, member IDs, frame timings, hashes -- and never checks in a
-- decoded texel. Runs only in the ROM-gated layer.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorGraphics = require("romdump.src.digest.FieldActorGraphics")
local FieldActorCompiler = require("romdump.src.digest.FieldActorCompiler")
local FieldActorCacheWriter = require("romdump.src.digest.FieldActorCacheWriter")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local manifest = require("data.manifests.field_actors")

local T = {}

-- The source-correlation set: the player graphics plus every class the two
-- target maps place. mapModelId is the actor's own NSBTX member; descriptor is
-- the visual selector in packed bits 10-15.
local EXPECTED = {
  { spriteId = 0, mapModelId = 69, packed = 0x1C60, descriptor = 7, label = "hero" },
  { spriteId = 97, mapModelId = 70, packed = 0x1C60, descriptor = 7, label = "heroine" },
  { spriteId = 29, mapModelId = 25, packed = 0x0000, descriptor = 0, label = "aide" },
  { spriteId = 34, mapModelId = 37, packed = 0x0000, descriptor = 0, label = "policeman" },
  { spriteId = 99, mapModelId = 54, packed = 0x0000, descriptor = 0, label = "professor" },
  { spriteId = 148, mapModelId = 58, packed = 0x0000, descriptor = 0, label = "rival" },
  { spriteId = 325, mapModelId = 123, packed = 0x0000, descriptor = 0, label = "woman 1" },
  { spriteId = 328, mapModelId = 126, packed = 0x0000, descriptor = 0, label = "man 1" },
  { spriteId = 332, mapModelId = 130, packed = 0x0000, descriptor = 0, label = "big man" },
  { spriteId = 365, mapModelId = 159, packed = 0x0000, descriptor = 0, label = "mother" },
  { spriteId = 1032, mapModelId = 483, packed = 0x4E27, descriptor = 19, label = "static Marill" },
}

local function decodeTable(romFs)
  local bytes, info = romFs:readOverlay(manifest.overlay.cpu, manifest.overlay.overlayId)
  Assert.notNil(bytes, "overlay 1 must be readable from the dump")
  return assert(FieldActorGraphics.decode(bytes, { ramAddress = info.ramAddress }, manifest)), info
end

function T.graphics_table_matches_the_source_derived_invariants(romFs)
  local decoded, info = decodeTable(romFs)
  Assert.equal(decoded.recordCount, manifest.tables.graphics.expectedRecordCount)
  Assert.equal(decoded.terminatorOffset, manifest.tables.graphics.expectedTerminatorOffset)
  Assert.equal(decoded.tableOffset, manifest.tables.graphics.address - info.ramAddress)
  Assert.equal(decoded.spanBytes, 5412)
end

function T.every_target_sprite_resolves_to_its_source_bundle(romFs)
  local decoded = decodeTable(romFs)
  for _, expected in ipairs(EXPECTED) do
    local resolved = assert(
      FieldActorGraphics.resolve(decoded, expected.spriteId),
      expected.label .. " must be present in the graphics table"
    )
    Assert.equal(resolved.record.mapModelId, expected.mapModelId, expected.label .. " NSBTX member")
    Assert.equal(resolved.record.packed, expected.packed, expected.label .. " packed word")
    Assert.equal(resolved.record.visualDescriptor, expected.descriptor, expected.label .. " visual descriptor")
    -- Every target class shares the same billboard model member.
    Assert.equal(resolved.descriptor.modelMemberId, 266, expected.label .. " shared model")
  end
end

function T.the_variable_friend_sprite_is_absent_by_design(romFs)
  local decoded = decodeTable(romFs)
  local record, err = FieldActorGraphics.resolve(decoded, manifest.variableSpriteRange.first)
  Assert.isNil(record, "SPRITE_VAR_1 resolves through a field variable, not the table")
  Assert.equal(assert(err).code, "FIELD_ACTOR_SPRITE_ABSENT")
end

function T.player_and_ordinary_timelines_differ_as_the_source_says(romFs)
  local decoded = decodeTable(romFs)
  local hero = assert(FieldActorGraphics.resolve(decoded, 0))
  local aide = assert(FieldActorGraphics.resolve(decoded, 29))
  local marill = assert(FieldActorGraphics.resolve(decoded, 1032))
  Assert.equal(hero.descriptor.timelineMemberId, 281)
  Assert.equal(aide.descriptor.timelineMemberId, 280)
  Assert.equal(marill.descriptor.timelineMemberId, 292)
  Assert.equal(#hero.descriptor.ranges, 8, "the player descriptor carries a second directional set")
  Assert.equal(#aide.descriptor.ranges, 4)
  Assert.equal(#marill.descriptor.ranges, 4)
end

function T.compiled_visuals_cover_the_target_maps(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local compiled = {}
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    compiled[spriteId] = true
  end
  for _, expected in ipairs(EXPECTED) do
    Assert.isTrue(compiled[expected.spriteId], expected.label .. " must be compiled")
  end
  local previous
  for _, spriteId in ipairs(bundle.index.variableSprites) do
    Assert.isTrue(
      spriteId >= manifest.variableSpriteRange.first and spriteId <= manifest.variableSpriteRange.last,
      "deferred sprite IDs stay inside the variable range"
    )
    Assert.isTrue(not previous or spriteId > previous, "deferred sprite IDs are sorted and unique")
    previous = spriteId
  end
  Assert.equal(bundle.index.variableSprites[1], manifest.variableSpriteRange.first)
  for _, avatar in ipairs(manifest.avatars) do
    Assert.isTrue(compiled[avatar.spriteId], avatar.id .. " variable target must be compiled")
  end

  local aide = bundle.visuals[29]
  Assert.equal(aide.render.frameWidth, 32)
  Assert.equal(aide.render.frameHeight, 32)
  Assert.equal(aide.render.billboardMode, "cameraFacingFull")
  Assert.isFalse(aide.render.mirrorEastWest)
  Assert.equal(aide.anchor.y, manifest.placement.modelYOffset)
  -- Four directions, each a four-frame loop of four ticks.
  for _, direction in ipairs(manifest.directionOrder) do
    local walk = aide.directions[direction].walk
    Assert.equal(#walk.frames, 4, direction .. " walk frame count")
    Assert.equal(walk.durationTicks, 16, direction .. " walk duration")
    Assert.equal(walk.frames[1].ticks, 4)
  end
  -- East is never a mirror of west: the two use different source texture slots.
  Assert.isTrue(
    aide.frames[aide.directions.west.walk.frames[1].frameIndex].textureSlot
      ~= aide.frames[aide.directions.east.walk.frames[1].frameIndex].textureSlot
  )
end

-- The render facts every target class must inherit from the shared model member:
-- one bottom-centered quad two tiles on a side, drawn single-sided in modulation
-- mode at full polygon alpha under polygon id 0, lit from the field profile
-- through its own normal. This is the answer to how actor polygons take part in
-- edge marking, read from the ROM rather than assumed.
function T.the_shared_model_supplies_one_lit_cutout_quad(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  for _, expected in ipairs(EXPECTED) do
    local render = bundle.visuals[expected.spriteId].render
    local geometry, polygon = render.geometry, render.polygon
    Assert.equal(geometry.modelName, "mmdl_m32x32", expected.label .. " model")
    Assert.equal(#geometry.vertices, 4, expected.label .. " quad vertices")
    Assert.equal(#geometry.indices, 6)
    Assert.equal(geometry.bounds.width, 2, expected.label .. " quad width in tiles")
    Assert.equal(geometry.bounds.height, 2)
    Assert.equal(geometry.bounds.depth, 0)
    Assert.equal(geometry.anchorTiles.x, 0)
    Assert.equal(geometry.anchorTiles.y, 0)
    Assert.equal(geometry.anchorTiles.z, manifest.placement.modelOffset.z / 16)
    Assert.equal(render.alphaClass, "cutout", expected.label .. " alpha class")
    Assert.equal(polygon.polygonAlpha, 31)
    Assert.equal(polygon.polygonMode, "modulation")
    Assert.equal(polygon.polygonId, 0)
    Assert.equal(polygon.cullMode, "back")
    Assert.equal(polygon.lightMask, 1)
    for _, vertex in ipairs(geometry.vertices) do
      Assert.equal(vertex.colorSource, 1, expected.label .. " vertex is normal-lit")
      Assert.isTrue(vertex.u == 0 or vertex.u == 1, "UVs span exactly one atlas frame")
    end
  end
end

function T.marill_keeps_its_uneven_south_loop(romFs)
  local bundle = assert(FieldActorCompiler.compile(romFs))
  local south = bundle.visuals[1032].directions.south.walk
  Assert.equal(south.durationTicks, 20)
  Assert.deepEqual({ south.frames[1].ticks, south.frames[2].ticks, south.frames[3].ticks }, { 5, 10, 5 })
  Assert.equal(south.frames[1].frameIndex, south.frames[3].frameIndex, "the loop returns to its first slot")
end

function T.compilation_is_deterministic_and_writes_a_ready_cache(romFs, version)
  local first = assert(FieldActorCompiler.compile(romFs))
  local second = assert(FieldActorCompiler.compile(romFs))
  Assert.equal(first.marker, second.marker)

  local cache = CacheFs.forVersion(version, FakeCache.new())
  Assert.equal(FieldActorCacheWriter.write(cache, first), first.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, first.marker))

  local other = CacheFs.forVersion(version, FakeCache.new())
  FieldActorCacheWriter.write(other, second)
  for _, spriteId in ipairs(first.index.spriteIds) do
    Assert.equal(
      cache:read(FieldActorCache.atlasPath(spriteId)),
      other:read(FieldActorCache.atlasPath(spriteId)),
      "atlas bytes are reproducible"
    )
    Assert.equal(
      cache:read(FieldActorCache.visualPath(spriteId)),
      other:read(FieldActorCache.visualPath(spriteId)),
      "visual bytes are reproducible"
    )
  end
end

return T
