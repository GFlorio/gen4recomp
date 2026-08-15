-- FieldRenderCapabilities is a static declaration, not a stateful module, so
-- the unit contract is simply: every field the ROM census keys against
-- exists with the shape the census expects, and the declared truth matches
-- what the current renderer/compiler pipeline actually does (a real code
-- path exists), not what the DS ideally requires.

local Assert = require("tests.support.Assert")
local FieldRenderCapabilities = require("libs.engine.src.FieldRenderCapabilities")

local T = {}

function T.declares_the_polygon_modes_the_shader_actually_branches_on()
  Assert.isTrue(FieldRenderCapabilities.polygonModes.modulation)
  Assert.isTrue(FieldRenderCapabilities.polygonModes.decal)
  -- map.glsl's u_polygonMode is a 0/1 switch (decal or modulation); toon and
  -- shadow have no combiner path and are rejected at compile time
  -- (MAP_COMPILE_UNSUPPORTED_POLYGON_MODE), so they must not be declared.
  Assert.isFalse(FieldRenderCapabilities.polygonModes.toon)
  Assert.isFalse(FieldRenderCapabilities.polygonModes.shadow)
end

function T.declares_every_cull_mode_setMeshCullMode_receives()
  Assert.isTrue(FieldRenderCapabilities.cullModes.back)
  Assert.isTrue(FieldRenderCapabilities.cullModes.front)
  Assert.isTrue(FieldRenderCapabilities.cullModes.none)
end

function T.declares_every_texture_format_TextureDecoder_supports()
  for format = 1, 7 do
    Assert.isTrue(FieldRenderCapabilities.textureFormats[format], "format " .. format)
  end
end

function T.declares_every_alpha_class_the_render_queue_partitions()
  local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
  Assert.isTrue(FieldRenderCapabilities.alphaClasses[AlphaClassifier.OPAQUE])
  Assert.isTrue(FieldRenderCapabilities.alphaClasses[AlphaClassifier.CUTOUT])
  Assert.isTrue(FieldRenderCapabilities.alphaClasses[AlphaClassifier.TRANSLUCENT])
  Assert.isTrue(FieldRenderCapabilities.alphaClasses[AlphaClassifier.WIREFRAME])
end

-- GX states with a real (if approximate) code path in the current renderer.
function T.declares_states_the_renderer_actually_implements_supported()
  Assert.isTrue(FieldRenderCapabilities.depthEqual, "depthEqual maps to host lequal")
  Assert.isTrue(FieldRenderCapabilities.translucentDepthWrite, "bit-11 drives host depth-write toggling")
  Assert.isTrue(FieldRenderCapabilities.wireframe, "love.graphics.setWireframe draws the wireframe pass")
  Assert.isTrue(FieldRenderCapabilities.billboard, "u_billboard drives the whole billboard vertex path")
  Assert.isTrue(FieldRenderCapabilities.fog, "map.glsl reads u_polygonFogEnabled/u_fogEnabled and applies DsFog")
  Assert.isTrue(FieldRenderCapabilities.mirroredRepeat, "SceneDescriptor.wrap folds flip+repeat into mirroredrepeat")
end

return { tests = T }
