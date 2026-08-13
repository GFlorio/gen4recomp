-- Payload-free report over a compiled field-actor bundle. Prints the structural
-- facts: table span, descriptor resolution, per-sprite resource
-- tuple, frame inventory, and pose timing -- without emitting any ROM-derived
-- image or texel byte. Pure: it formats an already-compiled bundle.

local AlphaClassifier = require("libs.assets.src.AlphaClassifier")

local FieldActorInspector = {}

local function poseSummary(pose)
  local parts = {}
  for _, frame in ipairs(pose.frames) do
    parts[#parts + 1] = frame.frameIndex - 1 .. "x" .. frame.ticks
  end
  return table.concat(parts, ",")
end

function FieldActorInspector.inspect(bundle)
  local provenance = assert(bundle.provenance, "actor bundle provenance is required")
  local sprites = {}
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    local visual = bundle.visuals[spriteId]
    local atlas = bundle.atlases[spriteId]
    local record = provenance.records[spriteId]
    local descriptor = provenance.descriptors[record.visualDescriptor]
    sprites[#sprites + 1] = {
      spriteId = spriteId,
      visual = visual,
      atlas = atlas,
      record = record,
      descriptor = descriptor,
      staticModelMemberId = provenance.staticModels and provenance.staticModels.bySpriteId[spriteId] or nil,
      -- Overlay static models use their own archive member; a shared model
      -- member compiled as static falls back to its descriptor's member id.
      modelMemberId = descriptor.modelMemberId,
    }
  end
  return {
    overlay = bundle.dependencies.overlay,
    recordCount = bundle.index.recordCount,
    variableSprites = bundle.index.variableSprites,
    sprites = sprites,
  }
end

function FieldActorInspector.lines(report)
  local out = {}
  local overlay = report.overlay
  out[#out + 1] = string.format(
    "actors\ttable\trecords=%d\tramAddress=0x%08X\ttableOffset=0x%X\tspan=%d\tsha1=%s",
    report.recordCount,
    overlay.ramAddress,
    overlay.tableOffset,
    overlay.spanBytes,
    overlay.spanSha1
  )
  for _, spriteId in ipairs(report.variableSprites) do
    out[#out + 1] =
      string.format("actors\tvariable\tspriteId=%d\tresolved through a field variable before lookup", spriteId)
  end
  for _, entry in ipairs(report.sprites) do
    local v, a = entry.visual, entry.atlas
    local record, descriptor = entry.record, entry.descriptor
    local parts = v.render.kind == "staticModel" and v.render.parts or { v.render }
    for partIndex, part in ipairs(parts) do
      local geometry, polygon = part.geometry, part.polygon
      out[#out + 1] = string.format(
        "actors\tmodel\tid=%d\tpart=%d\tname=%s\tsize=%.3fx%.3fx%.3f tiles"
          .. "\talpha=%s\tpolyAttr=0x%08X\tpolygonId=%d\tpolygonAlpha=%d\tmode=%s"
          .. "\tlightMask=0x%X\tcull=%s\tcolorSource=%d",
        v.spriteId,
        partIndex,
        geometry.modelName,
        geometry.bounds.width,
        geometry.bounds.height,
        geometry.bounds.depth,
        part.alphaClass,
        polygon.polygonAttrRaw,
        polygon.polygonId,
        polygon.polygonAlpha,
        polygon.polygonMode,
        polygon.lightMask,
        polygon.cullMode,
        geometry.vertices[1].colorSource
      )
    end
    if v.render.kind == "staticModel" then
      out[#out + 1] = string.format(
        "actors\tsprite\tid=%d\tstaticModel=%d\tpacked=0x%04X\tdescriptor=%d" .. "\tparts=%d\tatlas=%dx%d",
        v.spriteId,
        entry.staticModelMemberId or entry.modelMemberId,
        record.packed,
        record.visualDescriptor,
        #v.render.parts,
        a.width,
        a.height
      )
    else
      out[#out + 1] = string.format(
        "actors\tsprite\tid=%d\ttexture=%d\tmodel=%d\ttimeline=%d\tpacked=0x%04X"
          .. "\tdescriptor=%d\tframes=%d\tatlas=%dx%d\talpha=%s",
        v.spriteId,
        record.mapModelId,
        descriptor.modelMemberId,
        descriptor.timelineMemberId,
        record.packed,
        record.visualDescriptor,
        v.render.frameCount,
        a.width,
        a.height,
        (v.render.alphaUsage.hasZero and AlphaClassifier.CUTOUT or AlphaClassifier.OPAQUE)
      )
    end
    for _, direction in ipairs({ "north", "south", "west", "east" }) do
      local pose = v.directions[direction]
      out[#out + 1] = string.format(
        "actors\tpose\tid=%d\t%s\tidle=%d\twalk=%s\tloop=%s",
        v.spriteId,
        direction,
        pose.idle.frames[1].frameIndex - 1,
        poseSummary(pose.walk),
        tostring(pose.walk.loop)
      )
    end
    if v.directionalSet2 then
      out[#out + 1] =
        string.format("actors\tpose\tid=%d\tdirectionalSet2\t%s", v.spriteId, poseSummary(v.directionalSet2.north))
    end
  end
  return out
end

return FieldActorInspector
