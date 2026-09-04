-- Builds the per-frame billboard meshes of a compiled field actor.
--
-- The compiled visual carries the shared actor quad exactly as the ROM's model
-- member draws it -- billboard-local vertices in tiles, normalized UVs over one
-- frame, the source normal and vertex-colour source -- plus a horizontal atlas
-- strip of every frame its poses can reach. One mesh per frame is therefore the
-- same quad with its U range slid onto that frame, which lets a draw select a
-- pose by index instead of mutating shared vertex data mid-frame.
--
-- love-coupled, but the graphics namespace is injectable so the geometry maths
-- stays testable headless. Build once per resident sprite, never during a draw.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local VertexFormat = require("libs.assets.src.model.VertexFormat")

local FieldActorMesh = {}

-- Vertex-attribute rows in VertexFormat.LAYOUT order, with the frame's U slide
-- applied and colours normalized to 0..1 as the shader expects.
function FieldActorMesh.frameVertices(geometry, frameIndex, frameCount)
  assert(type(geometry) == "table" and type(geometry.vertices) == "table", "actor geometry requires vertices")
  assert(
    frameIndex >= 1 and frameIndex <= frameCount,
    "frame index " .. tostring(frameIndex) .. " is outside the atlas strip"
  )
  local rows = {}
  for index, vertex in ipairs(geometry.vertices) do
    rows[index] = {
      vertex.x,
      vertex.y,
      vertex.z,
      (frameIndex - 1 + vertex.u) / frameCount,
      vertex.v,
      vertex.nx,
      vertex.ny,
      vertex.nz,
      vertex.r / 255,
      vertex.g / 255,
      vertex.b / 255,
      (vertex.a or 255) / 255,
      vertex.colorSource,
    }
  end
  return rows
end

-- One mesh per atlas frame. `graphics` is a love.graphics-shaped namespace.
-- Runtime-only callers use FieldActorDefinitionProvider; this presentation
-- builder always owns real mesh resources.
function FieldActorMesh.build(graphics, visual)
  assert(type(visual) == "table" and type(visual.render) == "table", "FieldActorMesh requires a compiled actor visual")
  assert(graphics and graphics.newMesh, "FieldActorMesh requires love.graphics")
  local render = visual.render
  local geometries = {}
  if render.kind == "staticModel" then
    for _, part in ipairs(render.parts or {}) do
      geometries[#geometries + 1] = part.geometry
    end
  else
    geometries[1] = render.geometry
  end
  for _, geometry in ipairs(geometries) do
    if not (geometry and geometry.vertices and geometry.indices) then
      Errors.raise(
        FieldErrors.FIELD_ACTOR_GEOMETRY_MISSING,
        "compiled visual for spriteId " .. tostring(visual.spriteId) .. " carries no geometry",
        { spriteId = visual.spriteId }
      )
    end
  end
  if #geometries == 0 then
    Errors.raise(
      FieldErrors.FIELD_ACTOR_GEOMETRY_MISSING,
      "compiled visual for spriteId " .. tostring(visual.spriteId) .. " carries no geometry",
      { spriteId = visual.spriteId }
    )
  end
  local meshes = {}
  local count = render.kind == "staticModel" and #geometries or render.frameCount
  local ok, err = pcall(function()
    for meshIndex = 1, count do
      local geometry = render.kind == "staticModel" and geometries[meshIndex] or geometries[1]
      local frameIndex = render.kind == "staticModel" and 1 or meshIndex
      local map = {}
      for i, index in ipairs(geometry.indices) do
        map[i] = index + 1
      end
      local mesh = graphics.newMesh(
        VertexFormat.LAYOUT,
        FieldActorMesh.frameVertices(geometry, frameIndex, render.kind == "staticModel" and 1 or render.frameCount),
        "triangles",
        "static"
      )
      mesh:setVertexMap(map)
      meshes[meshIndex] = mesh
    end
  end)
  if not ok then
    FieldActorMesh.release(meshes)
    error(err, 0)
  end
  return meshes
end

function FieldActorMesh.release(meshes)
  for _, mesh in ipairs(meshes or {}) do
    if mesh.release then
      mesh:release()
    end
  end
end

return FieldActorMesh
