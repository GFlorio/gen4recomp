-- Freezes what the shared field-actor model member must supply: one billboard
-- quad, bottom-centered in tiles, UVs over the whole actor texture, and the
-- effective polygon state the runtime draws it with. Every byte comes from the
-- synthetic NSBMD fixture; no ROM model is committed.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local FieldActorModel = require("romdump.src.digest.FieldActorModel")

local T = {}

local PLACEMENT = {
  sourceSize = { width = 32, height = 32 },
  pivot = { x = 0.5, y = 1.0 },
  modelYOffset = 6,
}

local function compile(bytes, opts)
  opts = opts or {}
  opts.placement = opts.placement or PLACEMENT
  -- Format 3 (palette16) with colour-zero transparency, as the actor textures are.
  opts.textureFormat = opts.textureFormat or 3
  opts.alphaUsage = opts.alphaUsage or { hasZero = true, hasOpaque = true, hasPartial = false }
  return FieldActorModel.compile(bytes, opts)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

function T.compiles_the_bottom_centered_billboard_quad()
  local result = compile(NsbmdFixture.buildBillboardQuad())
  Assert.equal(#result.vertices, 4)
  Assert.equal(#result.indices, 6)
  Assert.near(result.bounds.width, 2, 1e-6, "32 model units is two tiles wide")
  Assert.near(result.bounds.height, 2, 1e-6)
  Assert.near(result.bounds.depth, 0, 1e-6, "the actor quad is flat")

  local minY = math.huge
  for _, vertex in ipairs(result.vertices) do minY = math.min(minY, vertex.y) end
  Assert.near(minY, 0, 1e-6, "the quad rests on its own origin, which is the actor's feet")
end

function T.normalizes_uvs_and_keeps_the_source_normal_and_colour_source()
  local result = compile(NsbmdFixture.buildBillboardQuad())
  local minU, maxU = math.huge, -math.huge
  for _, vertex in ipairs(result.vertices) do
    minU, maxU = math.min(minU, vertex.u), math.max(maxU, vertex.u)
    Assert.near(vertex.nz, 1, 0.01, "the quad faces its own +Z")
    Assert.equal(vertex.colorSource, 1, "the display list issues NORMAL, so the vertex is lit")
  end
  Assert.near(minU, 0, 1e-6)
  Assert.near(maxU, 1, 1e-6, "texel UVs are normalized to one atlas frame")
end

function T.reports_the_billboard_base_transform()
  local result = compile(NsbmdFixture.buildBillboardQuad())
  Assert.equal(#result.baseTransform, 16, "a billboard draw carries its captured position matrix")
  Assert.equal(result.modelName, "m0")
end

function T.resolves_the_polygon_draw_state()
  local result = compile(NsbmdFixture.buildBillboardQuad())
  Assert.equal(result.alphaClass, "cutout", "colour-zero texels make the actor a cutout draw")
  Assert.equal(result.polygon.polygonAlpha, 31)
  Assert.equal(result.polygon.polygonMode, "modulation")
  Assert.equal(result.polygon.lightMask, 1)
  Assert.equal(result.polygon.cullMode, "back", "the actor material renders one surface")
  Assert.isTrue(result.polygon.fogEnabled)
  Assert.equal(result.polygon.polygonId, 0)
end

function T.an_opaque_texture_stays_opaque()
  local result = compile(NsbmdFixture.buildBillboardQuad(),
    { alphaUsage = { hasZero = false, hasOpaque = true, hasPartial = false } })
  Assert.equal(result.alphaClass, "opaque")
end

function T.rejects_a_translucent_actor_texture()
  -- Format 1 is A3I5, which the DS always blends; the actor pass draws neither
  -- translucent nor wireframe geometry.
  throwsCode("FIELD_ACTOR_MODEL_ALPHA_UNSUPPORTED", function()
    compile(NsbmdFixture.buildBillboardQuad(), { textureFormat = 1 })
  end)
end

function T.rejects_a_non_billboard_draw()
  throwsCode("FIELD_ACTOR_MODEL_NOT_BILLBOARD", function()
    -- One static draw of the triangle shape: a model that never enters BB.
    compile(NsbmdFixture.buildTransformed())
  end)
end

function T.rejects_a_quad_that_is_not_the_expected_plane()
  throwsCode("FIELD_ACTOR_MODEL_PLACEMENT_UNEXPECTED", function()
    compile(NsbmdFixture.buildBillboardQuad({ size = 16 }))
  end)
end

function T.rejects_uvs_that_do_not_cover_the_texture()
  throwsCode("FIELD_ACTOR_MODEL_UV_UNEXPECTED", function()
    compile(NsbmdFixture.buildBillboardQuad({ uvSize = 16 }))
  end)
end

function T.rejects_a_model_that_draws_more_than_one_shape()
  throwsCode("FIELD_ACTOR_MODEL_SHAPE_UNEXPECTED", function()
    -- NsbmdFixture.build draws its shape twice, which the shared actor model never does.
    compile(NsbmdFixture.build())
  end)
end

return T
