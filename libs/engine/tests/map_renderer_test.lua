-- Pure MapRenderer contracts that need no graphics context: the field-edge
-- radius derivation and the scene-schema gate. Everything that compiles a
-- shader, allocates a render target, or reads back driver state lives in
-- map_renderer_graphics_test.lua.

local Assert = require("tests.support.Assert")
local MapRenderer = require("libs.engine.src.MapRenderer")
local MapSceneLoader = require("libs.engine.src.MapSceneLoader")

local T = {}

function T.field_edge_radius_uses_only_viewport_height()
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(192), 1)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(384), 2)
  Assert.equal(MapRenderer.fieldEdgeRadiusPixels(1080), 6)
end

function T.rejects_stale_scene_schema()
  local ok, err = pcall(MapSceneLoader.load, nil, { schema = "g4-map-scene-v1" })
  Assert.isTrue(
    not ok and err.code == "MAP_SCENE_UNSUPPORTED_SCHEMA",
    "rejects old scene schema: " .. tostring(err.code)
  )
end

return T
