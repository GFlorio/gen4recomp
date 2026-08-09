-- Compiles every field-actor sprite referenced by the map catalog into normalized
-- `g4-field-actor-v1`
-- visual definitions plus one private RGBA atlas each.
--
-- Ordinary actors use a shared camera-facing billboard and timeline. Static
-- map-object models keep their source geometry and polygon parts. Both paths
-- normalize source textures into a private RGBA atlas.
-- See docs/adr/field-actor-visual-representation.md.
--
-- Every sprite-to-resource mapping is read from the ROM: the six-byte graphics
-- record gives the actor texture member, its packed word selects a visual
-- descriptor, and the descriptor's model/timeline keys resolve through the
-- overlay's own key tables. No spriteId -> member table is hardcoded.

local Errors = require("libs.rom.src.Errors")
local ZoneEvents = require("libs.assets.src.ZoneEvents")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local Hashing = require("romdump.src.digest.Hashing")
local AlphaClassifier = require("romdump.src.digest.AlphaClassifier")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local TextureDecoder = require("romdump.src.digest.nitro.TextureDecoder")
local FieldActorGraphics = require("romdump.src.digest.FieldActorGraphics")
local FieldActorFrames = require("romdump.src.digest.FieldActorFrames")
local FieldActorModel = require("romdump.src.digest.FieldActorModel")
local FieldActorStaticModel = require("romdump.src.digest.FieldActorStaticModel")
local FieldActorTimeline = require("romdump.src.digest.FieldActorTimeline")
local manifest = require("data.manifests.field_actors")

local FieldActorCompiler = {}

FieldActorCompiler.COMPILER_VERSION = "field-actor-compiler-v3"

local MODEL_MAGIC = "BMD0"
local TEXTURE_MAGIC = "BTX0"

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

-- The configured player graphics plus every object-event sprite used by any map
-- in the catalog. Variable sprite IDs are
-- resolved by the runtime to a player graphic and are never compiled directly.
local function selectedSpriteIds(romFs)
  local variable = manifest.variableSpriteRange
  local wanted, order = {}, {}
  local function add(spriteId)
    if wanted[spriteId] then
      return
    end
    wanted[spriteId] = true
    order[#order + 1] = spriteId
  end
  for _, avatar in ipairs(manifest.avatars) do
    add(avatar.spriteId)
  end

  local archive = must(romFs:openNarc("zone_events"), "zone_event archive is unavailable")
  local variableSprites = {}
  for map in MapCatalog.all() do
    local decoded = must(
      ZoneEvents.decode(
        must(archive:readMember(map.eventMemberId)),
        { mapId = map.id, eventMemberId = map.eventMemberId }
      )
    )
    for _, object in ipairs(decoded.objectEvents) do
      if object.spriteId >= variable.first and object.spriteId <= variable.last then
        variableSprites[object.spriteId] = true
      else
        add(object.spriteId)
      end
    end
  end

  table.sort(order)
  local deferred = {}
  for spriteId in pairs(variableSprites) do
    deferred[#deferred + 1] = spriteId
  end
  table.sort(deferred)
  return order, deferred
end

local function decodeAtlas(pack, frames, context)
  local width, height
  for _, frame in ipairs(frames) do
    local texture = pack.textures[frame.textureSlot + 1]
    if not texture then
      Errors.raise(
        "FIELD_ACTOR_TEXTURE_SLOT_MISSING",
        "timeline references texture slot " .. frame.textureSlot .. " but the actor resource has " .. #pack.textures,
        { textureSlot = frame.textureSlot, count = #pack.textures, context = context }
      )
    end
    local palette = pack.palettes[frame.paletteSlot + 1]
    if not palette then
      Errors.raise(
        "FIELD_ACTOR_PALETTE_SLOT_MISSING",
        "timeline references palette slot " .. frame.paletteSlot .. " but the actor resource has " .. #pack.palettes,
        { paletteSlot = frame.paletteSlot, count = #pack.palettes, context = context }
      )
    end
    width = width or texture.width
    height = height or texture.height
    if texture.width ~= width or texture.height ~= height then
      Errors.raise(
        "FIELD_ACTOR_FRAME_SIZE_MISMATCH",
        "actor frames must share one size; slot "
          .. frame.textureSlot
          .. " is "
          .. texture.width
          .. "x"
          .. texture.height
          .. ", expected "
          .. width
          .. "x"
          .. height,
        { textureSlot = frame.textureSlot, context = context }
      )
    end
    frame.texture, frame.paletteRecord = texture, palette
  end

  local decoded = {}
  local alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = false }
  local textureFormat
  for _, frame in ipairs(frames) do
    local format = pack.textures[frame.textureSlot + 1].formatRaw
    textureFormat = textureFormat or format
    if format ~= textureFormat then
      Errors.raise(
        "FIELD_ACTOR_FRAME_FORMAT_MISMATCH",
        "actor frames must share one texture format; slot "
          .. frame.textureSlot
          .. " is "
          .. format
          .. ", expected "
          .. textureFormat,
        { textureSlot = frame.textureSlot, context = context }
      )
    end
  end
  for i, frame in ipairs(frames) do
    local pixels = TextureDecoder.decode(Nsbtx.decoderOpts(pack, frame.texture, frame.paletteRecord), context)
    decoded[i] = pixels
    for key in pairs(alphaUsage) do
      alphaUsage[key] = alphaUsage[key] or pixels.alphaUsage[key]
    end
    frame.texture, frame.paletteRecord = nil, nil
  end

  -- Pack the frames into one horizontal strip, row by row.
  local rows, stride = {}, width * 4
  for y = 0, height - 1 do
    local row = {}
    for i = 1, #decoded do
      row[i] = decoded[i].pixels:sub(y * stride + 1, (y + 1) * stride)
    end
    rows[y + 1] = table.concat(row)
  end

  return {
    width = width * #frames,
    height = height,
    pixels = table.concat(rows),
    frameWidth = width,
    frameHeight = height,
    alphaUsage = alphaUsage,
    textureFormat = textureFormat,
  }
end

-- Turn per-range displayed frames into the direction-keyed pose sets. Ranges
-- 1-4 are the base directional set in global_fieldmap.h order; a descriptor with
-- eight ranges carries a second set whose gameplay trigger is not yet traced, so
-- it is preserved under a neutral name.
local function buildPoses(perRange, ranges, context)
  local order = manifest.directionOrder

  local function poseFor(index)
    local range = ranges[index]
    local frames = perRange[index]
    local ticks = 0
    for _, frame in ipairs(frames) do
      ticks = ticks + frame.ticks
    end
    return {
      frames = frames,
      loop = range.loop,
      durationTicks = ticks,
      sourceRange = { startFrame = range.startFrame, endFrame = range.endFrame, endMode = range.endMode },
    }
  end

  local directions, alternate = {}, nil
  if #ranges < #order then
    local animations = {}
    for index = 1, #ranges do
      animations[index] = poseFor(index)
    end
    for _, direction in ipairs(order) do
      directions[direction] = { idle = animations[1], walk = animations[1] }
    end
    return directions, nil, animations
  end
  for i, direction in ipairs(order) do
    local walk = poseFor(i)
    -- An idle actor never advances its animation clock, so it holds the first
    -- displayed frame of its facing range.
    directions[direction] = {
      idle = {
        frames = { { frameIndex = walk.frames[1].frameIndex, ticks = 1 } },
        loop = true,
        durationTicks = 1,
      },
      walk = walk,
    }
  end
  if #ranges >= #order * 2 then
    alternate = {}
    for i, direction in ipairs(order) do
      alternate[direction] = poseFor(#order + i)
    end
  end
  return directions, alternate, nil
end

local function staticDirections()
  local directions = {}
  for _, direction in ipairs(manifest.directionOrder) do
    local pose = { frames = { { frameIndex = 1, ticks = 1 } }, loop = true, durationTicks = 1 }
    directions[direction] = { idle = pose, walk = pose }
  end
  return directions
end

local function finishStaticModel(spriteId, record, compiled, sourceRecord)
  local render, atlas = compiled.render, compiled.atlas
  render.image = FieldActorCache.atlasPath(spriteId)
  local visual = {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    mapModelId = record.mapModelId,
    rawGraphicsFlags = record.packed,
    original = {
      movementProfile = record.movementProfile,
      actorFamily = record.actorFamily,
      visualDescriptor = record.visualDescriptor,
    },
    render = render,
    anchor = { x = 0, y = 0, z = 0 },
    bounds = { width = atlas.frameWidth, height = atlas.frameHeight, depth = 0 },
    pivot = { x = 0.5, y = 1 },
    frames = { { textureSlot = 0, paletteSlot = 0 } },
    directions = staticDirections(),
    source = sourceRecord,
  }
  return visual, atlas
end

local function compileStaticModel(spriteId, record, memberId, archive, source, context)
  local modelBytes = must(
    archive:readMember(memberId),
    Errors.new(
      "FIELD_ACTOR_STATIC_MODEL_MEMBER_MISSING",
      "static model member " .. memberId .. " is absent",
      { memberId = memberId, context = context }
    )
  )
  local compiled = FieldActorStaticModel.compile(modelBytes, context, nil, manifest.staticModels.archive.path)
  return finishStaticModel(spriteId, record, compiled, {
    archive = manifest.staticModels.archive.path,
    staticModelMemberId = memberId,
    graphicsRecordOffset = record.offset,
    overlaySha1 = source.overlaySha1,
    modelMemberSha1 = Hashing.sha1hex(modelBytes),
  })
end

local function compileSprite(romFs, spriteId, graphics, archive, staticArchive, source)
  local context = { spriteId = spriteId, romVersion = romFs:version() }
  local resolved = must(FieldActorGraphics.resolve(graphics, spriteId))
  local record = resolved.record
  if resolved.staticModelMemberId then
    return compileStaticModel(spriteId, record, resolved.staticModelMemberId, staticArchive, source, context)
  end
  local descriptor = resolved.descriptor

  local modelBytes = archive:readMember(descriptor.modelMemberId)
  if not modelBytes or modelBytes:sub(1, 4) ~= MODEL_MAGIC then
    Errors.raise(
      "FIELD_ACTOR_MODEL_MEMBER_INVALID",
      "shared model member " .. descriptor.modelMemberId .. " is not a " .. MODEL_MAGIC .. " resource",
      { memberId = descriptor.modelMemberId, context = context }
    )
  end
  local textureBytes = archive:readMember(record.mapModelId)
  if not textureBytes or textureBytes:sub(1, 4) ~= TEXTURE_MAGIC then
    Errors.raise(
      "FIELD_ACTOR_TEXTURE_MEMBER_INVALID",
      "actor texture member " .. record.mapModelId .. " is not a " .. TEXTURE_MAGIC .. " resource",
      { memberId = record.mapModelId, context = context }
    )
  end
  local timelineBytes = must(
    archive:readMember(descriptor.timelineMemberId),
    Errors.new(
      "FIELD_ACTOR_TIMELINE_MEMBER_MISSING",
      "timeline member " .. descriptor.timelineMemberId .. " is absent",
      { memberId = descriptor.timelineMemberId, context = context }
    )
  )

  local timeline = must(FieldActorTimeline.decode(timelineBytes, context))
  local pack = must(Nsbtx.decode(textureBytes, context))
  local drawMode = FieldActorModel.drawMode(modelBytes, context)
  if drawMode == "static" then
    local compiled = FieldActorStaticModel.compile(modelBytes, context, pack, manifest.archive.path)
    return finishStaticModel(spriteId, record, compiled, {
      archive = manifest.archive.path,
      modelMemberId = descriptor.modelMemberId,
      textureMemberId = record.mapModelId,
      timelineMemberId = descriptor.timelineMemberId,
      modelKey = descriptor.modelKey,
      timelineKey = descriptor.timelineKey,
      graphicsRecordOffset = record.offset,
      overlaySha1 = source.overlaySha1,
      textureMemberSha1 = Hashing.sha1hex(textureBytes),
      timelineMemberSha1 = Hashing.sha1hex(timelineBytes),
      modelMemberSha1 = Hashing.sha1hex(modelBytes),
    })
  end
  if drawMode ~= "billboard" then
    Errors.raise(
      "FIELD_ACTOR_MODEL_DRAW_MODE_UNSUPPORTED",
      "actor model draw mode is " .. drawMode,
      { drawMode = drawMode, context = context }
    )
  end
  local frameSet = FieldActorFrames.collect(timeline, descriptor.ranges, #pack.textures, #pack.palettes, context)
  local frames, perRange = frameSet.frames, frameSet.perRange
  local atlas = decodeAtlas(pack, frames, context)
  local directions, alternate, animations = buildPoses(perRange, descriptor.ranges, context)

  local placement = {
    sourceSize = { width = atlas.frameWidth, height = atlas.frameHeight },
    pivot = manifest.placement.pivot,
    modelOffset = manifest.placement.modelOffset,
    billboardMode = manifest.placement.billboardMode,
    mirrorEastWest = manifest.placement.mirrorEastWest,
  }
  -- The quad, its billboard base matrix, and its polygon state are replayed from
  -- the shared model member itself, so no actor render fact is hand-authored.
  local geometry = FieldActorModel.compile(modelBytes, {
    placement = placement,
    textureFormat = atlas.textureFormat,
    alphaUsage = atlas.alphaUsage,
    context = context,
  })
  local visual = {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    mapModelId = record.mapModelId,
    rawGraphicsFlags = record.packed,
    original = {
      movementProfile = record.movementProfile,
      actorFamily = record.actorFamily,
      visualDescriptor = record.visualDescriptor,
    },
    render = {
      kind = "atlas",
      animationMode = frameSet.mode,
      image = FieldActorCache.atlasPath(spriteId),
      frameWidth = atlas.frameWidth,
      frameHeight = atlas.frameHeight,
      frameCount = #frames,
      billboardMode = placement.billboardMode,
      mirrorEastWest = placement.mirrorEastWest,
      alphaUsage = atlas.alphaUsage,
      textureFormat = atlas.textureFormat,
      alphaClass = geometry.alphaClass,
      polygon = geometry.polygon,
      -- Billboard-local quad in runtime tiles, plus the position matrix the SBC
      -- billboard command captured; the runtime composes the actor's world
      -- placement onto it and resolves the pair against the live camera.
      geometry = {
        modelName = geometry.modelName,
        vertices = geometry.vertices,
        indices = geometry.indices,
        baseTransform = geometry.baseTransform,
        anchorTiles = geometry.anchorTiles,
        bounds = geometry.bounds,
      },
    },
    anchor = { x = 0, y = placement.modelYOffset, z = 0 },
    bounds = { width = atlas.frameWidth, height = atlas.frameHeight, depth = 0 },
    pivot = { x = placement.pivot.x, y = placement.pivot.y },
    frames = frames,
    directions = directions,
    directionalSet2 = alternate,
    nonDirectionalAnimations = animations,
    source = {
      archive = manifest.archive.path,
      modelMemberId = descriptor.modelMemberId,
      textureMemberId = record.mapModelId,
      timelineMemberId = descriptor.timelineMemberId,
      modelKey = descriptor.modelKey,
      timelineKey = descriptor.timelineKey,
      graphicsRecordOffset = record.offset,
      overlaySha1 = source.overlaySha1,
      textureMemberSha1 = Hashing.sha1hex(textureBytes),
      timelineMemberSha1 = Hashing.sha1hex(timelineBytes),
      modelMemberSha1 = Hashing.sha1hex(modelBytes),
    },
  }
  return visual, atlas
end

local function _compile(romFs)
  assert(romFs and romFs.readOverlay and romFs.openNarc, "compile requires a RomFs-shaped object")

  local overlayBytes, overlayInfo = romFs:readOverlay(manifest.overlay.cpu, manifest.overlay.overlayId)
  must(overlayBytes, overlayInfo)
  local graphics = must(FieldActorGraphics.decode(overlayBytes, { ramAddress = overlayInfo.ramAddress }, manifest))

  local archiveInfo = romFs:resolvedNarc(manifest.archive.alias)
  if not archiveInfo then
    Errors.raise(
      "ROMFS_NARC_UNRESOLVED",
      manifest.archive.alias .. " NARC is unavailable",
      { name = manifest.archive.alias }
    )
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc(manifest.archive.alias))
  local staticArchiveInfo = romFs:resolvedNarc(manifest.staticModels.archive.alias)
  if not staticArchiveInfo then
    Errors.raise(
      "ROMFS_NARC_UNRESOLVED",
      manifest.staticModels.archive.alias .. " NARC is unavailable",
      { name = manifest.staticModels.archive.alias }
    )
  end
  local staticArchiveBytes = must(romFs:read(staticArchiveInfo.fileId))
  local staticArchive = must(romFs:openNarc(manifest.staticModels.archive.alias))

  local source = {
    -- The logical table span only, not the whole overlay: a change anywhere else
    -- in overlay 1 must not invalidate compiled actors.
    overlaySha1 = Hashing.sha1hex(
      overlayBytes:sub(graphics.tableOffset + 1, graphics.tableOffset + graphics.spanBytes)
    ),
  }

  local spriteIds, variableSprites = selectedSpriteIds(romFs)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId], atlases[spriteId] = compileSprite(romFs, spriteId, graphics, archive, staticArchive, source)
  end

  local dependencies = {
    cacheFormat = FieldActorCache.FORMAT,
    schema = FieldActorCache.SCHEMA,
    compilerVersion = FieldActorCompiler.COMPILER_VERSION,
    graphicsDecoderVersion = FieldActorGraphics.DECODER_VERSION,
    timelineDecoderVersion = FieldActorTimeline.DECODER_VERSION,
    modelDecoderVersion = FieldActorModel.DECODER_VERSION,
    staticModelCompilerVersion = FieldActorStaticModel.COMPILER_VERSION,
    alphaClassifierVersion = AlphaClassifier.VERSION,
    manifestSchema = manifest.schema,
    mapCatalogVersion = MapCatalog.VERSION,
    versionRomSha1 = romFs:metadata().sha1,
    overlay = {
      cpu = manifest.overlay.cpu,
      overlayId = manifest.overlay.overlayId,
      ramAddress = overlayInfo.ramAddress,
      tableOffset = graphics.tableOffset,
      spanBytes = graphics.spanBytes,
      spanSha1 = source.overlaySha1,
    },
    archive = {
      symbol = archiveInfo.symbol,
      alias = archiveInfo.alias,
      narcId = archiveInfo.narcId,
      fileId = archiveInfo.fileId,
      path = archiveInfo.path,
      sha1 = Hashing.sha1hex(archiveBytes),
    },
    staticArchive = {
      symbol = staticArchiveInfo.symbol,
      alias = staticArchiveInfo.alias,
      narcId = staticArchiveInfo.narcId,
      fileId = staticArchiveInfo.fileId,
      path = staticArchiveInfo.path,
      sha1 = Hashing.sha1hex(staticArchiveBytes),
    },
    spriteIds = spriteIds,
  }

  local index = {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = romFs:version(),
    spriteIds = spriteIds,
    -- Sprite IDs the runtime must resolve through field variables before lookup;
    -- every value they take is one of the compiled player graphics.
    variableSpriteRange = manifest.variableSpriteRange,
    variableSprites = variableSprites,
    recordCount = graphics.recordCount,
  }

  local provenance = {
    schema = "g4-field-actor-provenance-v1",
    source = manifest.provenance,
    dependencies = dependencies,
    descriptors = graphics.descriptors,
    modelKeys = graphics.modelMembers.byKey,
    timelineKeys = graphics.timelineMembers.byKey,
    staticModels = graphics.staticModels,
  }

  return {
    marker = FieldActorCache.marker(romFs:metadata().sha1, Hashing.hashLua(dependencies)),
    index = index,
    visuals = visuals,
    atlases = atlases,
    dependencies = dependencies,
    provenance = provenance,
  }
end

function FieldActorCompiler.compile(romFs)
  local ok, result = pcall(_compile, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldActorCompiler
