-- Map-scoped terrain-animation compiler: owns every HGSS terrain-animation
-- coordination step for one map bundle. It parses the `fldtanime` table
-- (member 0 of `data/fldtanime.narc` in pret/pokeheartgold, dump alias
-- `field_texture_animations`) once, matches records against the decoded
-- model materials' texture names, lazily reads and decodes only the
-- replacement BTX0 members the central or neighbor terrain matched (cached
-- per member within the compilation), validates the compatibility of exactly
-- the replacement dictionary entries the live schedule references, decodes
-- each referenced alternate frame from the replacement texels under the base
-- material's palette, annotates scene-form materials with textureSwap.steps
-- records in schedule order, compiles the area NSBTA selected by the area's
-- dynamicTextureType (dump alias `field_area_texture_srt`, NARC_a_1_4_0)
-- through the shared clip compiler, and accumulates the dependency hashes the
-- map completion marker needs. One instance is scoped to one map bundle so
-- central and neighbor compiles contribute to one dependency set; there are
-- no module-global mutable caches. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local FieldTextureAnimation = require("romdump.src.digest.FieldTextureAnimation")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")

local TerrainAnimationCompiler = {}
TerrainAnimationCompiler.__index = TerrainAnimationCompiler

-- Structured error codes owned by this module.
TerrainAnimationCompiler.ERROR_MEMBER_OUT_OF_RANGE = "TERRAIN_ANIM_MEMBER_OUT_OF_RANGE"
TerrainAnimationCompiler.ERROR_TEXTURE_INDEX = "TERRAIN_ANIM_TEXTURE_INDEX_OUT_OF_RANGE"
TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE = "TERRAIN_ANIM_TEXTURE_INCOMPATIBLE"
TerrainAnimationCompiler.ERROR_SRT_MEMBER_OUT_OF_RANGE = "TERRAIN_ANIM_SRT_MEMBER_OUT_OF_RANGE"
TerrainAnimationCompiler.ERROR_SRT_NOT_NSBTA = "TERRAIN_ANIM_SRT_NOT_NSBTA"
TerrainAnimationCompiler.ERROR_EMPTY_SET = "TERRAIN_ANIM_EMPTY_SET"

local TABLE_ALIAS = "field_texture_animations"
local SRT_ALIAS = "field_area_texture_srt"
local TABLE_MEMBER_ID = 0
local NO_SRT = 0xFFFF

local function sourceContext(mapId, alias, memberId)
  return { alias = alias, memberId = memberId, mapId = mapId }
end

local function readMember(narc, alias, memberId, mapId)
  local count = narc:memberCount()
  if not (memberId >= 0 and memberId < count) then
    Errors.raise(
      TerrainAnimationCompiler.ERROR_MEMBER_OUT_OF_RANGE,
      alias .. " member " .. memberId .. " out of range (count " .. count .. ")",
      sourceContext(mapId, alias, memberId)
    )
  end
  return assert(narc:readMember(memberId))
end

-- Compiler object scoped to one map bundle. `dynamicTextureType` is the
-- area record's selection: 0xFFFF means no area texture-coordinate
-- animation, every other value is a zero-based `field_area_texture_srt`
-- member ID.
function TerrainAnimationCompiler.new(romFs, opts)
  assert(romFs and romFs.openNarc, "TerrainAnimationCompiler requires a RomFs-shaped object")
  assert(opts and opts.mapId ~= nil, "TerrainAnimationCompiler requires a mapId")
  assert(type(opts.dynamicTextureType) == "number", "TerrainAnimationCompiler requires a numeric dynamicTextureType")

  local narc = assert(romFs:openNarc(TABLE_ALIAS), "field_texture_animations archive is unavailable")
  local tableBytes = readMember(narc, TABLE_ALIAS, TABLE_MEMBER_ID, opts.mapId)
  local tableContext = sourceContext(opts.mapId, TABLE_ALIAS, TABLE_MEMBER_ID)
  local records, err = FieldTextureAnimation.parse(tableBytes, tableContext)
  if not records then
    error(err)
  end
  local recordsByName = {}
  for _, record in ipairs(records) do
    recordsByName[record.name] = record
  end

  return setmetatable({
    romFs = romFs,
    mapId = opts.mapId,
    dynamicTextureType = opts.dynamicTextureType,
    tableSha1 = Hashing.sha1hex(tableBytes),
    recordsByName = recordsByName,
    -- Decoded replacement packs keyed by member ID, read lazily and at most
    -- once per compilation; the raw member hash is recorded with it because
    -- a read member is by definition a used member.
    replacementPacks = {},
    -- memberId -> sha1 of the raw member bytes, only for members a matched
    -- material actually read.
    usedMemberHashes = {},
    srtDependency = nil, -- { memberId, sha1 } once the selected member is read
  }, TerrainAnimationCompiler)
end

-- Annotate one scene-form terrain material: find the fldtanime record
-- matching the decoded material's texture name, decode every replacement
-- dictionary texture the live schedule references under the base material's
-- palette into the caller's shared content-addressed accumulator, and return
-- the textureSwap record (or nil when no record matches or the material
-- failed texture binding, which leaves the material static and reads
-- nothing). `compiledMaterial` is the MaterialCompiler record for the same
-- material: its `texture` key is the base decode. The returned steps follow
-- the schedule order exactly; repeated source indices repeat the path, and
-- the base material's image stays outside the schedule.
function TerrainAnimationCompiler:annotateMaterial(modelMaterial, compiledMaterial, baseTexturePack, textures)
  local animationRecord = self.recordsByName[modelMaterial.textureName]
  if not animationRecord or not compiledMaterial.texture then
    return nil
  end

  local replMemberId = animationRecord.index + 1
  local replacementPack = self.replacementPacks[replMemberId]
  if not replacementPack then
    local bytes = readMember(assert(self.romFs:openNarc(TABLE_ALIAS)), TABLE_ALIAS, replMemberId, self.mapId)
    local pack, err = Nsbtx.decode(bytes, sourceContext(self.mapId, TABLE_ALIAS, replMemberId))
    if not pack then
      error(err)
    end
    replacementPack = pack
    self.usedMemberHashes[replMemberId] = Hashing.sha1hex(bytes)
    self.replacementPacks[replMemberId] = replacementPack
  end

  -- The base material's texture and palette from the caller's pack: the
  -- alternate frames keep the base format, dimensions, color0Transparent
  -- behavior, and palette, replacing only texel/index data.
  local baseTexture = baseTexturePack.textureByName[modelMaterial.textureName]
  assert(
    baseTexture,
    "matched terrain record " .. animationRecord.name .. " but the pack lacks texture " .. modelMaterial.textureName
  )
  local basePalette = modelMaterial.paletteName and baseTexturePack.paletteByName[modelMaterial.paletteName] or nil
  local baseDecoderOpts = Nsbtx.decoderOpts(baseTexturePack, baseTexture, basePalette)

  local steps = {}
  for scheduleIndex, sourceStep in ipairs(animationRecord.timeline) do
    local sourceIndex = sourceStep.textureIndex
    if sourceIndex >= #replacementPack.textures then
      Errors.raise(
        TerrainAnimationCompiler.ERROR_TEXTURE_INDEX,
        "fldtanime record "
          .. animationRecord.name
          .. " schedule textureIndex "
          .. sourceIndex
          .. " exceeds the replacement dictionary size "
          .. #replacementPack.textures,
        {
          record = animationRecord.name,
          recordIndex = animationRecord.index,
          scheduleIndex = scheduleIndex - 1,
          textureIndex = sourceIndex,
          dictionarySize = #replacementPack.textures,
          source = sourceContext(self.mapId, TABLE_ALIAS, replMemberId),
        }
      )
    end
    local replacementTexture = assert(replacementPack.textures[sourceIndex + 1])
    local replacementDecoderOpts = Nsbtx.decoderOpts(replacementPack, replacementTexture, nil)
    if
      replacementTexture.formatRaw ~= baseTexture.formatRaw
      or replacementTexture.width ~= baseTexture.width
      or replacementTexture.height ~= baseTexture.height
      or #replacementDecoderOpts.texel ~= #baseDecoderOpts.texel
      or (baseDecoderOpts.indexData and #replacementDecoderOpts.indexData ~= #baseDecoderOpts.indexData)
    then
      Errors.raise(
        TerrainAnimationCompiler.ERROR_TEXTURE_INCOMPATIBLE,
        "replacement texture "
          .. replacementTexture.name
          .. " for fldtanime record "
          .. animationRecord.name
          .. " is incompatible with base texture "
          .. modelMaterial.textureName,
        {
          record = animationRecord.name,
          recordIndex = animationRecord.index,
          material = modelMaterial.name,
          texture = modelMaterial.textureName,
          source = sourceContext(self.mapId, TABLE_ALIAS, replMemberId),
        }
      )
    end
    local frameOpts = {}
    for k, v in pairs(baseDecoderOpts) do
      frameOpts[k] = v
    end
    frameOpts.texel = replacementDecoderOpts.texel
    if baseDecoderOpts.indexData then
      frameOpts.indexData = replacementDecoderOpts.indexData
    end
    local key = MaterialCompiler.decodeTexture(baseTexture, frameOpts, textures, modelMaterial.textureName)
    steps[#steps + 1] = {
      texture = MapAssetCache.texturePath(key),
      durationTicks = sourceStep.durationTicks,
    }
  end
  return {
    name = animationRecord.name,
    steps = steps,
  }
end

-- Compile the area texture-coordinate animation selected by the area
-- record's dynamicTextureType into the data-only clip the runtime samples.
-- 0xFFFF emits false and reads no member. The clip envelope comes from the
-- shared NsbtaClipCompiler, the single NSBTA clip authority; the clip
-- carries no physical source/archive provenance.
---@return table|false
function TerrainAnimationCompiler:compileTextureSrt()
  if self.dynamicTextureType == NO_SRT then
    return false
  end

  local narc = assert(self.romFs:openNarc(SRT_ALIAS), "field_area_texture_srt archive is unavailable")
  if not (self.dynamicTextureType >= 0 and self.dynamicTextureType < narc:memberCount()) then
    Errors.raise(
      TerrainAnimationCompiler.ERROR_SRT_MEMBER_OUT_OF_RANGE,
      "area dynamicTextureType "
        .. self.dynamicTextureType
        .. " selects no field_area_texture_srt member (count "
        .. narc:memberCount()
        .. ")",
      { dynamicTextureType = self.dynamicTextureType, memberCount = narc:memberCount(), mapId = self.mapId }
    )
  end
  local bytes = assert(narc:readMember(self.dynamicTextureType))
  local decoded, err = NitroAnimation.decode(bytes, sourceContext(self.mapId, SRT_ALIAS, self.dynamicTextureType))
  if not decoded then
    error(err)
  end
  if decoded.format ~= "NSBTA" then
    Errors.raise(
      TerrainAnimationCompiler.ERROR_SRT_NOT_NSBTA,
      "area dynamicTextureType selects member "
        .. self.dynamicTextureType
        .. " of field_area_texture_srt, which decodes as "
        .. decoded.format
        .. " instead of NSBTA",
      { format = decoded.format, dynamicTextureType = self.dynamicTextureType, mapId = self.mapId }
    )
  end
  if #decoded.animations == 0 then
    Errors.raise(
      TerrainAnimationCompiler.ERROR_EMPTY_SET,
      "selected area texture-SRT member " .. self.dynamicTextureType .. " contains no animations",
      { dynamicTextureType = self.dynamicTextureType, mapId = self.mapId }
    )
  end
  -- The area selection uses the first decoded animation, exactly like HGSS.
  local animationRecord = decoded.animations[1]

  self.srtDependency = { memberId = self.dynamicTextureType, sha1 = Hashing.sha1hex(bytes) }
  local clip = NsbtaClipCompiler.compile(
    animationRecord.resource,
    BinaryReader.new(decoded.bytes, "srt0-section"),
    #decoded.bytes,
    {
      id = animationRecord.name,
      name = animationRecord.name,
      semanticNames = {},
    }
  )
  clip.source = nil
  return clip
end

-- The deterministic dependency record for the map completion marker:
-- the fldtanime table hash unconditionally, the hashes of only the
-- replacement members used by the compiled central or neighbor terrain
-- (sorted by member ID), and the selected area NSBTA member or false.
function TerrainAnimationCompiler:dependencies()
  local memberIds = {}
  for memberId in pairs(self.usedMemberHashes) do
    memberIds[#memberIds + 1] = memberId
  end
  table.sort(memberIds)
  local memberSha1s = {}
  for _, memberId in ipairs(memberIds) do
    memberSha1s[#memberSha1s + 1] = { memberId = memberId, sha1 = self.usedMemberHashes[memberId] }
  end
  return {
    fieldTextureAnimations = {
      tableSha1 = self.tableSha1,
      memberSha1s = memberSha1s,
    },
    terrainTextureSrt = self.srtDependency or false,
  }
end

return TerrainAnimationCompiler
