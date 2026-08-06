-- Compiles the selected field-actor sprites into normalized `g4-field-actor-v1`
-- visual definitions plus one private RGBA atlas each.
--
-- The original engine draws every actor in this class as a single 32x32 quad
-- (shared `mmodel` model member, Nitro full camera-facing billboard) whose
-- texture and palette are swapped per animation frame by a timeline resource.
-- The atlas representation is therefore lossless: each distinct (texture slot,
-- palette slot) pair the sprite's animation ranges can reach is decoded once and
-- packed into a horizontal strip, and the pose data references strip frames.
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
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local TextureDecoder = require("romdump.src.digest.nitro.TextureDecoder")
local FieldActorGraphics = require("romdump.src.digest.FieldActorGraphics")
local FieldActorTimeline = require("romdump.src.digest.FieldActorTimeline")
local manifest = require("data.manifests.field_actors")

local FieldActorCompiler = {}

FieldActorCompiler.COMPILER_VERSION = "field-actor-compiler-v1"

local MODEL_MAGIC = "BMD0"
local TEXTURE_MAGIC = "BTX0"

local function must(value, err)
  if value == nil then error(err) end
  return value
end

-- The selected set: the configured always-compiled player graphics plus every
-- object-event sprite used by the configured maps. Variable sprite IDs are
-- resolved by the runtime to a player graphic and are never compiled directly.
local function selectedSpriteIds(romFs)
  local variable = manifest.variableSpriteRange
  local wanted, order = {}, {}
  local function add(spriteId)
    if wanted[spriteId] then return end
    wanted[spriteId] = true
    order[#order + 1] = spriteId
  end
  for _, spriteId in ipairs(manifest.selectedSet.alwaysSprites) do add(spriteId) end

  local archive = must(romFs:openNarc("zone_events"), "zone_event archive is unavailable")
  local variableSprites = {}
  for _, symbol in ipairs(manifest.selectedSet.maps) do
    local map = MapCatalog.require(symbol)
    local decoded = must(ZoneEvents.decode(must(archive:readMember(map.eventMemberId)),
      { mapId = map.id, eventMemberId = map.eventMemberId }))
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
  for spriteId in pairs(variableSprites) do deferred[#deferred + 1] = spriteId end
  table.sort(deferred)
  return order, deferred
end

-- Collect the (textureSlot, paletteSlot) pairs every animation range of this
-- descriptor can display, in a deterministic first-seen order.
local function collectFrames(timeline, ranges)
  local frames, byKey = {}, {}
  local perRange = {}
  for index, range in ipairs(ranges) do
    local displayed = FieldActorTimeline.framesForRange(timeline, range)
    local mapped = {}
    for _, frame in ipairs(displayed) do
      local key = frame.textureSlot .. ":" .. frame.paletteSlot
      local frameIndex = byKey[key]
      if not frameIndex then
        frames[#frames + 1] = { textureSlot = frame.textureSlot, paletteSlot = frame.paletteSlot }
        frameIndex = #frames
        byKey[key] = frameIndex
      end
      mapped[#mapped + 1] = { frameIndex = frameIndex, ticks = frame.ticks }
    end
    perRange[index] = mapped
  end
  return frames, perRange
end

local function decodeAtlas(pack, frames, context)
  local width, height
  for _, frame in ipairs(frames) do
    local texture = pack.textures[frame.textureSlot + 1]
    if not texture then
      Errors.raise("FIELD_ACTOR_TEXTURE_SLOT_MISSING",
        "timeline references texture slot " .. frame.textureSlot .. " but the actor resource has "
          .. #pack.textures, { textureSlot = frame.textureSlot, count = #pack.textures,
            context = context })
    end
    local palette = pack.palettes[frame.paletteSlot + 1]
    if not palette then
      Errors.raise("FIELD_ACTOR_PALETTE_SLOT_MISSING",
        "timeline references palette slot " .. frame.paletteSlot .. " but the actor resource has "
          .. #pack.palettes, { paletteSlot = frame.paletteSlot, count = #pack.palettes,
            context = context })
    end
    width = width or texture.width
    height = height or texture.height
    if texture.width ~= width or texture.height ~= height then
      Errors.raise("FIELD_ACTOR_FRAME_SIZE_MISMATCH",
        "actor frames must share one size; slot " .. frame.textureSlot .. " is "
          .. texture.width .. "x" .. texture.height .. ", expected " .. width .. "x" .. height,
        { textureSlot = frame.textureSlot, context = context })
    end
    frame.texture, frame.paletteRecord = texture, palette
  end

  local source = manifest.placement.sourceSize
  if width ~= source.width or height ~= source.height then
    Errors.raise("FIELD_ACTOR_UNEXPECTED_FRAME_SIZE",
      "actor frames are " .. width .. "x" .. height .. ", expected "
        .. source.width .. "x" .. source.height,
      { width = width, height = height, context = context })
  end

  local decoded = {}
  local alphaUsage = { hasZero = false, hasPartial = false, hasOpaque = false }
  for i, frame in ipairs(frames) do
    local pixels = TextureDecoder.decode(
      Nsbtx.decoderOpts(pack, frame.texture, frame.paletteRecord), context)
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
  }
end

-- Turn per-range displayed frames into the direction-keyed pose sets. Ranges
-- 1-4 are the base directional set in global_fieldmap.h order; a descriptor with
-- eight ranges carries a second set whose gameplay trigger is not yet traced, so
-- it is preserved under a neutral name.
local function buildPoses(perRange, ranges, context)
  local order = manifest.directionOrder
  if #ranges < #order then
    Errors.raise("FIELD_ACTOR_RANGES_INCOMPLETE",
      "descriptor provides " .. #ranges .. " animation ranges, need " .. #order,
      { count = #ranges, required = #order, context = context })
  end

  local function poseFor(index)
    local range = ranges[index]
    local frames = perRange[index]
    local ticks = 0
    for _, frame in ipairs(frames) do ticks = ticks + frame.ticks end
    return {
      frames = frames,
      loop = range.loop,
      durationTicks = ticks,
      sourceRange = { startFrame = range.startFrame, endFrame = range.endFrame,
        endMode = range.endMode },
    }
  end

  local directions, alternate = {}, nil
  for i, direction in ipairs(order) do
    local walk = poseFor(i)
    -- An idle actor never advances its animation clock, so it holds the first
    -- displayed frame of its facing range.
    directions[direction] = {
      idle = { frames = { { frameIndex = walk.frames[1].frameIndex, ticks = 1 } },
               loop = true, durationTicks = 1 },
      walk = walk,
    }
  end
  if #ranges >= #order * 2 then
    alternate = {}
    for i, direction in ipairs(order) do
      alternate[direction] = poseFor(#order + i)
    end
  end
  return directions, alternate
end

local function compileSprite(romFs, spriteId, graphics, archive, source)
  local context = { spriteId = spriteId, romVersion = romFs:version() }
  local resolved = must(FieldActorGraphics.resolve(graphics, spriteId))
  local record, descriptor = resolved.record, resolved.descriptor

  local modelBytes = archive:readMember(descriptor.modelMemberId)
  if not modelBytes or modelBytes:sub(1, 4) ~= MODEL_MAGIC then
    Errors.raise("FIELD_ACTOR_MODEL_MEMBER_INVALID",
      "shared model member " .. descriptor.modelMemberId .. " is not a " .. MODEL_MAGIC
        .. " resource", { memberId = descriptor.modelMemberId, context = context })
  end
  local textureBytes = archive:readMember(record.mapModelId)
  if not textureBytes or textureBytes:sub(1, 4) ~= TEXTURE_MAGIC then
    Errors.raise("FIELD_ACTOR_TEXTURE_MEMBER_INVALID",
      "actor texture member " .. record.mapModelId .. " is not a " .. TEXTURE_MAGIC
        .. " resource", { memberId = record.mapModelId, context = context })
  end
  local timelineBytes = must(archive:readMember(descriptor.timelineMemberId),
    Errors.new("FIELD_ACTOR_TIMELINE_MEMBER_MISSING",
      "timeline member " .. descriptor.timelineMemberId .. " is absent",
      { memberId = descriptor.timelineMemberId, context = context }))

  local timeline = must(FieldActorTimeline.decode(timelineBytes, context))
  local pack = must(Nsbtx.decode(textureBytes, context))
  local frames, perRange = collectFrames(timeline, descriptor.ranges)
  local atlas = decodeAtlas(pack, frames, context)
  local directions, alternate = buildPoses(perRange, descriptor.ranges, context)

  local placement = manifest.placement
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
      image = FieldActorCache.atlasPath(spriteId),
      frameWidth = atlas.frameWidth,
      frameHeight = atlas.frameHeight,
      frameCount = #frames,
      billboardMode = placement.billboardMode,
      mirrorEastWest = placement.mirrorEastWest,
      alphaUsage = atlas.alphaUsage,
    },
    anchor = { x = 0, y = placement.modelYOffset, z = 0 },
    bounds = { width = atlas.frameWidth, height = atlas.frameHeight, depth = 0 },
    pivot = { x = placement.pivot.x, y = placement.pivot.y },
    frames = frames,
    directions = directions,
    directionalSet2 = alternate,
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
  local graphics = must(FieldActorGraphics.decode(overlayBytes,
    { ramAddress = overlayInfo.ramAddress }, manifest))

  local archiveInfo = romFs:resolvedNarc(manifest.archive.alias)
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", manifest.archive.alias .. " NARC is unavailable",
      { name = manifest.archive.alias })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc(manifest.archive.alias))

  local source = {
    -- The logical table span only, not the whole overlay: a change anywhere else
    -- in overlay 1 must not invalidate compiled actors.
    overlaySha1 = Hashing.sha1hex(overlayBytes:sub(graphics.tableOffset + 1,
      graphics.tableOffset + graphics.spanBytes)),
  }

  local spriteIds, variableSprites = selectedSpriteIds(romFs)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId], atlases[spriteId] = compileSprite(romFs, spriteId, graphics, archive, source)
  end

  local dependencies = {
    cacheFormat = FieldActorCache.FORMAT,
    schema = FieldActorCache.SCHEMA,
    compilerVersion = FieldActorCompiler.COMPILER_VERSION,
    graphicsDecoderVersion = FieldActorGraphics.DECODER_VERSION,
    timelineDecoderVersion = FieldActorTimeline.DECODER_VERSION,
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
      symbol = archiveInfo.symbol, alias = archiveInfo.alias, narcId = archiveInfo.narcId,
      fileId = archiveInfo.fileId, path = archiveInfo.path,
      sha1 = Hashing.sha1hex(archiveBytes),
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
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return FieldActorCompiler
