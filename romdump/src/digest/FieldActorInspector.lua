-- Payload-free report over a compiled field-actor bundle. Prints the structural
-- facts Gate 1 asks for -- table span, descriptor resolution, per-sprite resource
-- tuple, frame inventory, and pose timing -- without emitting any ROM-derived
-- image or texel byte. Pure: it formats an already-compiled bundle.

local FieldActorInspector = {}

local function poseSummary(pose)
  local parts = {}
  for _, frame in ipairs(pose.frames) do
    parts[#parts + 1] = frame.frameIndex - 1 .. "x" .. frame.ticks
  end
  return table.concat(parts, ",")
end

function FieldActorInspector.inspect(bundle)
  local sprites = {}
  for _, spriteId in ipairs(bundle.index.spriteIds) do
    local visual = bundle.visuals[spriteId]
    local atlas = bundle.atlases[spriteId]
    sprites[#sprites + 1] = { spriteId = spriteId, visual = visual, atlas = atlas }
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
    report.recordCount, overlay.ramAddress, overlay.tableOffset, overlay.spanBytes,
    overlay.spanSha1)
  for _, spriteId in ipairs(report.variableSprites) do
    out[#out + 1] = string.format(
      "actors\tvariable\tspriteId=%d\tresolved through a field variable before lookup", spriteId)
  end
  for _, entry in ipairs(report.sprites) do
    local v, a = entry.visual, entry.atlas
    out[#out + 1] = string.format(
      "actors\tsprite\tid=%d\ttexture=%d\tmodel=%d\ttimeline=%d\tpacked=0x%04X"
        .. "\tdescriptor=%d\tframes=%d\tatlas=%dx%d\talpha=%s",
      v.spriteId, v.source.textureMemberId, v.source.modelMemberId, v.source.timelineMemberId,
      v.rawGraphicsFlags, v.original.visualDescriptor, v.render.frameCount, a.width, a.height,
      (v.render.alphaUsage.hasZero and "cutout" or "opaque"))
    for _, direction in ipairs({ "north", "south", "west", "east" }) do
      local pose = v.directions[direction]
      out[#out + 1] = string.format("actors\tpose\tid=%d\t%s\tidle=%d\twalk=%s\tloop=%s",
        v.spriteId, direction, pose.idle.frames[1].frameIndex - 1, poseSummary(pose.walk),
        tostring(pose.walk.loop))
    end
    if v.directionalSet2 then
      out[#out + 1] = string.format("actors\tpose\tid=%d\tdirectionalSet2\t%s",
        v.spriteId, poseSummary(v.directionalSet2.north))
    end
  end
  return out
end

return FieldActorInspector
