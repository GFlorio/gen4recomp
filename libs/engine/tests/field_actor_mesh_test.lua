-- The per-frame billboard meshes must keep the compiled quad intact and change
-- nothing but the U range, so a pose selection is an index rather than a vertex
-- rewrite. Driven against a stub graphics namespace; no GPU resource is created.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorMesh = require("libs.engine.src.FieldActorMesh")

local T = {}

local function graphics(built, opts)
  opts = opts or {}
  local calls = 0
  return {
    newMesh = function(layout, vertices, mode, usage)
      calls = calls + 1
      if opts.failOnNewMesh == calls then
        error("injected newMesh failure")
      end
      local mesh = { layout = layout, vertices = vertices, mode = mode, usage = usage }
      function mesh:setVertexMap(map)
        self.map = map
      end
      function mesh:release()
        self.released = true
      end
      built[#built + 1] = mesh
      return mesh
    end,
  }
end

function T.slides_only_the_u_range_onto_the_frame()
  local visual = FieldActorFixture.visual(29, { frameCount = 4 })
  local rows = FieldActorMesh.frameVertices(visual.render.geometry, 3, 4)
  Assert.equal(#rows, 4)
  -- Row layout is VertexFormat.LAYOUT: position, texcoord, normal, colour, source.
  Assert.equal(rows[1][1], -1, "position is untouched")
  Assert.equal(rows[1][2], 0)
  Assert.near(rows[1][4], 0.5, 1e-9, "frame 3 of 4 starts halfway along the strip")
  Assert.near(rows[2][4], 0.75, 1e-9, "and spans exactly one frame width")
  Assert.equal(rows[1][5], 1, "V is unchanged")
  Assert.equal(rows[1][8], 1, "the source normal survives")
  Assert.equal(rows[1][13], 1, "so does the vertex colour source")
end

function T.normalizes_vertex_colours()
  local visual = FieldActorFixture.visual(29)
  visual.render.geometry.vertices[1].r = 255
  local rows = FieldActorMesh.frameVertices(visual.render.geometry, 1, 5)
  Assert.equal(rows[1][9], 1, "colours reach the shader in 0..1")
  Assert.equal(rows[1][12], 1)
end

function T.builds_one_mesh_per_frame_with_the_compiled_index_map()
  local built = {}
  local meshes = FieldActorMesh.build(graphics(built), FieldActorFixture.visual(29, { frameCount = 3 }))
  Assert.equal(#meshes, 3)
  Assert.equal(#built, 3)
  Assert.deepEqual(built[1].map, { 1, 2, 3, 1, 3, 4 }, "zero-based file indices become love's 1-based map")
  Assert.equal(built[1].mode, "triangles")
  Assert.equal(built[1].usage, "static")
end

function T.builds_one_mesh_per_static_model_part()
  local built = {}
  local visual = FieldActorFixture.visual(183, { frameCount = 1 })
  local geometry = visual.render.geometry
  visual.render.kind = "staticModel"
  visual.render.geometry = nil
  visual.render.parts = { { geometry = geometry }, { geometry = geometry } }
  local meshes = FieldActorMesh.build(graphics(built), visual)
  Assert.equal(#meshes, 2)
  Assert.equal(#built, 2)
end

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    FieldActorMesh.build(nil, FieldActorFixture.visual(29))
  end)
  Assert.isTrue(tostring(err):find("FieldActorMesh requires love.graphics", 1, true) ~= nil)
end

function T.a_visual_without_geometry_is_fatal()
  local visual = FieldActorFixture.visual(29)
  visual.render.geometry = nil
  local err = Assert.throws(function()
    FieldActorMesh.build(graphics({}), visual)
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_ACTOR_GEOMETRY_MISSING",
    "expected FIELD_ACTOR_GEOMETRY_MISSING, got " .. tostring(err)
  )
end

function T.releases_every_mesh()
  local built = {}
  local meshes = FieldActorMesh.build(graphics(built), FieldActorFixture.visual(29, { frameCount = 2 }))
  FieldActorMesh.release(meshes)
  Assert.isTrue(built[1].released and built[2].released)
end

function T.failed_mesh_construction_releases_already_acquired_meshes()
  local built = {}
  local err = Assert.throws(function()
    FieldActorMesh.build(graphics(built, { failOnNewMesh = 2 }), FieldActorFixture.visual(29, { frameCount = 2 }))
  end)
  Assert.isTrue(tostring(err):find("injected newMesh failure", 1, true) ~= nil)
  Assert.equal(#built, 1)
  Assert.isTrue(built[1].released, "the mesh acquired before the failure must be released")
end

return T
