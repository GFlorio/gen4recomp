-- Map-scoped terrain-animation compiler: owns every HGSS terrain-animation
-- coordination step for one map bundle. It parses the `fldtanime` table
-- (member 0 of `data/fldtanime.narc` in pret/pokeheartgold, dump alias
-- `field_texture_animations`) once, matches records against the decoded
-- model materials' texture names, lazily reads and decodes only the
-- replacement BTX0 members the central or neighbor terrain matched (cached
-- per member within the compilation), validates replacement compatibility
-- and schedule dictionary indices, decodes alternate frames from the
-- replacement texels under the base material's palette, annotates
-- scene-form materials with textureSwap records, compiles the one area
-- NSBTA selected by the area's dynamicTextureType (dump alias
-- `field_area_texture_srt`, NARC_a_1_4_0), and accumulates the dependency
-- hashes the map completion marker needs. One instance is scoped to one map
-- bundle so central and neighbor compiles contribute to one dependency set;
-- there are no module-global mutable caches. Pure domain module; LÖVE is
-- needed only for the Hashing helper.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")
local AnimationClip = require("libs.assets.src.AnimationClip")
local FieldTextureAnimation = require("romdump.src.digest.FieldTextureAnimation")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")

local TerrainAnimationCompiler = {}
TerrainAnimationCompiler.__index = TerrainAnimationCompiler

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
      "TERRAIN_ANIM_MEMBER_OUT_OF_RANGE",
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
    srtClip = nil, -- compiled clip or false once compileTextureSrt runs
  }, TerrainAnimationCompiler)
end

-- Annotate one scene-form terrain material: find the fldtanime record
-- matching the decoded material's texture name, decode every replacement
-- dictionary texture under the base material's palette into the caller's
-- shared content-addressed accumulator, and return the textureSwap record
-- (or nil when no record matches, which leaves the material static and
-- reads nothing). `record` is the MaterialCompiler record for the same
-- material: its `texture` key is the base decode, and the frame-0 slot of
-- the returned textureSwap always points at it -- the generated contract
-- requires textures[timeline[1].textureIndex + 1] == material.texture, and
-- the game shows the map-pack texture until the first schedule switch.
function TerrainAnimationCompiler:annotateMaterial(modelMaterial, record, pack, textures)
  local anim = self.recordsByName[modelMaterial.textureName]
  -- An all-sentinel record has no live frames: nothing can animate, so the
  -- material stays static and its replacement member is never read.
  if not anim or #anim.timeline == 0 or not record.texture then
    return nil
  end

  local replMemberId = anim.index + 1
  local replPack = self.replacementPacks[replMemberId]
  if not replPack then
    local bytes = readMember(assert(self.romFs:openNarc(TABLE_ALIAS)), TABLE_ALIAS, replMemberId, self.mapId)
    local pack, err = Nsbtx.decode(bytes, sourceContext(self.mapId, TABLE_ALIAS, replMemberId))
    if not pack then
      error(err)
    end
    replPack = pack
    self.usedMemberHashes[replMemberId] = Hashing.sha1hex(bytes)
    self.replacementPacks[replMemberId] = replPack
  end

  local swap = { name = anim.name, textures = {}, timeline = {} }
  for i, entry in ipairs(anim.timeline) do
    if entry.textureIndex >= #replPack.textures then
      Errors.raise(
        "TERRAIN_ANIM_TEXTURE_INDEX_OUT_OF_RANGE",
        "fldtanime record "
          .. anim.name
          .. " schedule textureIndex "
          .. entry.textureIndex
          .. " exceeds the replacement dictionary size "
          .. #replPack.textures,
        {
          record = anim.name,
          recordIndex = anim.index,
          scheduleIndex = i - 1,
          textureIndex = entry.textureIndex,
          dictionarySize = #replPack.textures,
          source = sourceContext(self.mapId, TABLE_ALIAS, replMemberId),
        }
      )
    end
    swap.timeline[#swap.timeline + 1] = {
      textureIndex = entry.textureIndex,
      durationTicks = entry.durationTicks,
    }
  end

  -- The base material's texture and palette from the caller's pack: the
  -- alternate frames keep the base format, dimensions, color0Transparent
  -- behavior, and palette, replacing only texel/index data.
  local tex = pack.textureByName[modelMaterial.textureName]
  assert(tex, "matched terrain record " .. anim.name .. " but the pack lacks texture " .. modelMaterial.textureName)
  local pal = modelMaterial.paletteName and pack.paletteByName[modelMaterial.paletteName] or nil
  local baseOpts = Nsbtx.decoderOpts(pack, tex, pal)

  local frame0Index = swap.timeline[1].textureIndex + 1
  for i, replTex in ipairs(replPack.textures) do
    local replOpts = Nsbtx.decoderOpts(replPack, replTex, nil)
    if
      replTex.formatRaw ~= tex.formatRaw
      or replTex.width ~= tex.width
      or replTex.height ~= tex.height
      or #replOpts.texel ~= #baseOpts.texel
      or (baseOpts.indexData and #replOpts.indexData ~= #baseOpts.indexData)
    then
      Errors.raise(
        "TERRAIN_ANIM_TEXTURE_INCOMPATIBLE",
        "replacement texture "
          .. replTex.name
          .. " for fldtanime record "
          .. anim.name
          .. " is incompatible with base texture "
          .. modelMaterial.textureName,
        {
          record = anim.name,
          recordIndex = anim.index,
          material = modelMaterial.name,
          texture = modelMaterial.textureName,
          source = sourceContext(self.mapId, TABLE_ALIAS, replMemberId),
        }
      )
    end
    if i == frame0Index then
      -- The DS shows the bound map-pack texture until the first schedule
      -- switch (`FieldTextureManager_LoadTexture`/`FieldTextureManager_Free`
      -- in pret/pokeheartgold's overlay 1), and that texture is an authoring
      -- snapshot, not necessarily the schedule's first entry -- the real
      -- sea_on/dsea_on records ship the last frame as the base. The contract
      -- (textures[timeline[1].textureIndex + 1] == material.texture) pins
      -- the frame-0 slot to the base image by construction; divergent
      -- entry-0 texels are never decoded, because the runtime cycle shows
      -- the base image at every first-entry position.
      swap.textures[i] = MapAssetCache.texturePath(record.texture)
    else
      local frameOpts = {}
      for k, v in pairs(baseOpts) do
        frameOpts[k] = v
      end
      frameOpts.texel = replOpts.texel
      if baseOpts.indexData then
        frameOpts.indexData = replOpts.indexData
      end
      local key = MaterialCompiler.decodeTexture(tex, frameOpts, textures, modelMaterial.textureName)
      swap.textures[i] = MapAssetCache.texturePath(key)
    end
  end
  return swap
end

-- Compile the area texture-coordinate animation selected by the area
-- record's dynamicTextureType into the data-only clip the runtime samples.
-- 0xFFFF emits false and reads no member. Returns the compiled clip or
-- false; the clip carries no physical source/archive provenance.
---@return table|false
function TerrainAnimationCompiler:compileTextureSrt()
  if self.dynamicTextureType == NO_SRT then
    return false
  end
  if self.srtClip ~= nil then
    return self.srtClip
  end

  local narc = assert(self.romFs:openNarc(SRT_ALIAS), "field_area_texture_srt archive is unavailable")
  if not (self.dynamicTextureType >= 0 and self.dynamicTextureType < narc:memberCount()) then
    Errors.raise(
      "TERRAIN_ANIM_SRT_MEMBER_OUT_OF_RANGE",
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
      "TERRAIN_ANIM_SRT_NOT_NSBTA",
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
      "TERRAIN_ANIM_EMPTY_SET",
      "selected area texture-SRT member " .. self.dynamicTextureType .. " contains no animations",
      { dynamicTextureType = self.dynamicTextureType, mapId = self.mapId }
    )
  end
  if #decoded.animations > 1 then
    Errors.raise(
      "TERRAIN_ANIM_AMBIGUOUS_SET",
      "selected area texture-SRT member "
        .. self.dynamicTextureType
        .. " contains "
        .. #decoded.animations
        .. " animations; one is required",
      { dynamicTextureType = self.dynamicTextureType, animationCount = #decoded.animations, mapId = self.mapId }
    )
  end

  local anim = decoded.animations[1]
  local reader = BinaryReader.new(decoded.bytes, "srt0-section")
  local payload = NsbtaClipCompiler.compilePayload(anim.resource, reader, #decoded.bytes, anim.name)
  local tracks = {}
  for i, target in ipairs(payload.targets) do
    tracks[#tracks + 1] = { target = target.name, targetIndex = i - 1 }
  end

  self.srtDependency = { memberId = self.dynamicTextureType, sha1 = Hashing.sha1hex(bytes) }
  self.srtClip = {
    id = anim.name,
    name = anim.name,
    category = AnimationClip.CATEGORIES.material,
    kind = AnimationClip.KINDS.TEXSRT,
    frameCount = anim.resource.numFrame,
    tracks = tracks,
    semanticNames = {},
    compiled = payload,
  }
  return self.srtClip
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
