-- Turns presentation-neutral actor draw records into map-renderer draw items.
--
-- An actor is world geometry, not UI: it enters the same queue as terrain and
-- building batches and carries the polygon state the ROM's actor material
-- declares (modulation, full polygon alpha, polygon id 0, colour-zero cutout),
-- so it depth-tests against map geometry and takes part in edge marking exactly
-- as the original does. The quad is a Nitro full camera-facing billboard, so the
-- item ships a `billboardBase` -- the actor's world placement composed onto the
-- position matrix the SBC command captured -- and MapRenderer rebuilds the real
-- matrix against the live camera each frame.
--
-- Pure domain module: matrix arithmetic only, no love dependency.

local Errors = require("libs.rom.src.Errors")
local FieldActorPose = require("libs.engine.src.FieldActorPose")
local Matrix4 = require("libs.math.src.Matrix4")

local FieldActorDraw = {}

-- Actor draws are submitted after map geometry; the base keeps their submission
-- order stable and distinct from the scene's own indices.
FieldActorDraw.SUBMISSION_BASE = 200000

local function requireMesh(entry, meshIndex, record)
  local mesh = entry.meshes and entry.meshes[meshIndex]
  if mesh then return mesh end
  Errors.raise("ACTOR_DRAW_FRAME_MISSING",
    "actor " .. tostring(record.actorId) .. " selected mesh " .. tostring(meshIndex)
      .. ", which the resident visual does not provide",
    { actorId = record.actorId, spriteId = record.spriteId, frameIndex = meshIndex })
end

-- record: an ActorDrawRecord (actorId, spriteId, world, facing, pose, poseTick).
-- entry: the resident FieldActorAssetProvider entry for that sprite.
function FieldActorDraw.item(record, entry, submissionIndex, partIndex)
  assert(type(record) == "table" and type(record.world) == "table", "a draw record needs a world position")
  assert(type(entry) == "table" and type(entry.visual) == "table", "a draw record needs its visual asset")
  local visual = entry.visual
  local render = visual.render
  local part = render.kind == "staticModel" and assert(render.parts[partIndex or 1]) or render
  local geometry = part.geometry
  local frameIndex, poseFellBack = FieldActorPose.frameIndex(visual, record.facing,
    record.pose or "idle", record.poseTick or 0)

  local anchor = geometry.anchorTiles
  local placement = Matrix4.translate(record.world.x + anchor.x,
    record.world.y + anchor.y, record.world.z + anchor.z)
  local billboardBase
  if render.kind ~= "staticModel" then
    billboardBase = Matrix4.multiply(placement, geometry.baseTransform)
  end
  local transform = billboardBase or placement
  local polygon = part.polygon
  local image = entry.image
  if part.textured == false then image = nil end

  return {
    mesh = requireMesh(entry, render.kind == "staticModel" and (partIndex or 1) or frameIndex, record),
    material = { image = image, alphaClass = part.alphaClass },
    transform = transform,
    billboardBase = billboardBase,
    alphaClass = part.alphaClass,
    cullMode = polygon.cullMode,
    polygonAlpha = polygon.polygonAlpha / 31,
    polygonMode = polygon.polygonMode,
    lightMask = polygon.lightMask,
    polygonId = polygon.polygonId,
    translucentDepthWrite = polygon.translucentDepthWrite,
    depthEqual = polygon.depthEqual,
    center = geometry.center or { 0, geometry.bounds.height / 2, 0 },
    submissionIndex = FieldActorDraw.SUBMISSION_BASE + (submissionIndex or 0),
    actorId = record.actorId,
    spriteId = record.spriteId,
    frameIndex = frameIndex,
    poseFellBack = poseFellBack,
  }
end

-- Draw items for a whole record list. `assetFor(spriteId)` returns the resident
-- provider entry; a record whose visual is absent is a programming fault, not a
-- reason to skip a frame.
function FieldActorDraw.items(records, assetFor)
  assert(type(assetFor) == "function", "FieldActorDraw.items needs an asset lookup")
  local items = {}
  for index, record in ipairs(records) do
    if record.visible ~= false then
      local entry = assetFor(record.spriteId)
      if not entry then
        Errors.raise("ACTOR_DRAW_VISUAL_MISSING",
          "actor " .. tostring(record.actorId) .. " has no resident visual for spriteId "
            .. tostring(record.spriteId),
          { actorId = record.actorId, spriteId = record.spriteId })
      end
      if entry.visual.render.kind == "staticModel" then
        for partIndex = 1, #entry.visual.render.parts do
          items[#items + 1] = FieldActorDraw.item(record, entry,
            index * 100 + partIndex, partIndex)
        end
      else
        items[#items + 1] = FieldActorDraw.item(record, entry, index)
      end
    end
  end
  return items
end

return FieldActorDraw
