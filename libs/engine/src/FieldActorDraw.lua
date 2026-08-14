-- Turns presentation-neutral actor draw records into map-renderer draw items.
--
-- An actor is world geometry, not UI: it enters the same queue as terrain and
-- building batches and carries the polygon state the ROM's actor material
-- declares (modulation, full polygon alpha, polygon id 0, colour-zero cutout),
-- so it depth-tests against map geometry and takes part in edge marking exactly
-- as the original does. The quad is a Nitro full camera-facing billboard, so the
-- item ships its world-space center and base scale; the vertex shader supplies
-- the camera-facing axes without rebuilding a model matrix on the CPU.
--
-- Pure domain module: matrix arithmetic only, no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldActorPose = require("libs.engine.src.FieldActorPose")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local FixedPoint = require("libs.math.src.FixedPoint")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")

local FieldActorDraw = {}

-- Draw items carry no submission numbers: queue traversal orders every part
-- and draw in source order, positionally.

-- The identity UV-transform matrix of actor materials (actors carry no
-- texture-SRT): the renderer reads the material's texMatrix directly.
local IDENTITY_TEX_MATRIX = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

local function requireMesh(entry, meshIndex, record)
  local mesh = entry.meshes and entry.meshes[meshIndex]
  if mesh then
    return mesh
  end
  Errors.raise(
    "ACTOR_DRAW_FRAME_MISSING",
    "actor "
      .. tostring(record.actorId)
      .. " selected mesh "
      .. tostring(meshIndex)
      .. ", which the resident visual does not provide",
    { actorId = record.actorId, spriteId = record.spriteId, frameIndex = meshIndex }
  )
end

-- record: an ActorDrawRecord (actorId, spriteId, world, facing, pose, poseTick).
-- entry: the resident FieldActorAssetProvider entry for that sprite.
-- partIndex: for a static model, the part to draw (1-based).
function FieldActorDraw.item(record, entry, partIndex)
  assert(type(record) == "table" and type(record.world) == "table", "a draw record needs a world position")
  assert(type(entry) == "table" and type(entry.visual) == "table", "a draw record needs its visual asset")
  local visual = entry.visual
  local render = visual.render
  local part = render.kind == "staticModel" and assert(render.parts[partIndex or 1]) or render
  local geometry = part.geometry
  local frameIndex, poseFellBack =
    FieldActorPose.frameIndex(visual, record.facing, record.pose or "idle", record.poseTick or 0)

  local anchor = geometry.anchorTiles
  local placement = Matrix4.translate(record.world.x + anchor.x, record.world.y + anchor.y, record.world.z + anchor.z)
  local isBillboard = render.kind ~= "staticModel"
  local billboardBase, billboardCenter, billboardScale
  if isBillboard then
    billboardBase = Matrix4.multiply(placement, geometry.baseTransform)
    billboardCenter = { billboardBase[13], billboardBase[14], billboardBase[15] }
    billboardScale = assert(
      entry.billboardScales and entry.billboardScales[geometry],
      "resident billboard visual is missing its precomputed scale"
    )
  end
  local transform = billboardBase or placement
  local polygon = part.polygon
  local image = entry.image
  if part.textured == false then
    image = nil
  end

  return {
    mesh = requireMesh(entry, render.kind == "staticModel" and (partIndex or 1) or frameIndex, record),
    material = { image = image, alphaClass = part.alphaClass, texMatrix = IDENTITY_TEX_MATRIX },
    transform = transform,
    -- Actor billboards and current static-model placements are translation
    -- only, so every actor item shares the same immutable normal transform.
    modelNormal = IDENTITY_MODEL_NORMAL,
    billboardBase = billboardBase,
    billboardCenter = billboardCenter,
    billboardScale = billboardScale,
    -- Actor quads draw through the depth-biased billboard projection (see
    -- FieldCamera:billboardProjection); static-model actors keep the world
    -- projection like the DS's 3D-object task manager.
    billboardProjection = isBillboard,
    alphaClass = part.alphaClass,
    -- The fragment cutoff is a render constant the shader reads only in
    -- cutout mode; the item contract requires a concrete value.
    alphaCutoff = AlphaClassifier.CUTOUT_EPSILON,
    cullMode = polygon.cullMode,
    polygonAlpha = polygon.polygonAlpha / FixedPoint.RGB5_MAX,
    polygonMode = polygon.polygonMode,
    lightMask = polygon.lightMask,
    polygonId = polygon.polygonId,
    translucentDepthWrite = polygon.translucentDepthWrite,
    depthEqual = polygon.depthEqual,
    center = geometry.center or { 0, geometry.bounds.height / 2, 0 },
    actorId = record.actorId,
    spriteId = record.spriteId,
    frameIndex = frameIndex,
    poseFellBack = poseFellBack,
  }
end

-- Draw items for a whole record list. `assetFor(spriteId)` returns the resident
-- provider entry; a record whose visual is absent is a programming fault, not a
-- reason to skip a frame. Static-model parts are emitted one item per part, in
-- source order for queue traversal.
function FieldActorDraw.items(records, assetFor)
  assert(type(assetFor) == "function", "FieldActorDraw.items needs an asset lookup")
  local items = {}
  for _, record in ipairs(records) do
    if record.visible ~= false then
      local entry = assetFor(record.spriteId)
      if not entry then
        Errors.raise(
          "ACTOR_DRAW_VISUAL_MISSING",
          "actor " .. tostring(record.actorId) .. " has no resident visual for spriteId " .. tostring(record.spriteId),
          { actorId = record.actorId, spriteId = record.spriteId }
        )
      end
      if entry.visual.render.kind == "staticModel" then
        for partIndex = 1, #entry.visual.render.parts do
          items[#items + 1] = FieldActorDraw.item(record, entry, partIndex)
        end
      else
        items[#items + 1] = FieldActorDraw.item(record, entry)
      end
    end
  end
  return items
end

return FieldActorDraw
