-- A special descriptor-63 object is a self-contained static NSBMD, not an
-- mmodel billboard. This synthetic fixture verifies its one-batch compile path.

local Assert = require("tests.support.Assert")
local NsbmdFixture = require("tests.support.NsbmdFixture")
local Tex0Fixture = require("tests.support.Tex0Fixture")
local FieldActorStaticModel = require("romdump.src.digest.FieldActorStaticModel")

local T = {}

function T.compiles_a_static_model_with_its_embedded_texture()
  local result = FieldActorStaticModel.compile(NsbmdFixture.buildStaticQuad({
    modelName = "book",
    origWidth = 8,
    origHeight = 8,
    embeddedTex0 = Tex0Fixture.block({ textures = { "tex0" }, palettes = { "pal0" } }),
  }))
  Assert.equal(result.render.kind, "staticModel")
  Assert.equal(result.render.parts[1].geometry.modelName, "book")
  Assert.isNil(result.render.parts[1].geometry.baseTransform)
  Assert.equal(result.atlas.width, 8)
  Assert.equal(result.atlas.height, 8)
  Assert.equal(#result.render.parts[1].geometry.vertices, 4)
end

return T
