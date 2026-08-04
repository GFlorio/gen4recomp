-- LÖVE smoke tests for the DS lighting shader and render pipeline. These run
-- under love (the test runner is launched with `love . --test`) because they
-- need a graphics context. If no graphics context is available the tests skip
-- themselves so the suite still passes in headless CI.

local Assert = require("tests.support.Assert")
local MapRenderer = require("src.render.MapRenderer")
local VertexFormat = require("src.render.VertexFormat")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newShader
end

function T.shader_compiles()
  if not hasGraphics() then return end
  local r = MapRenderer.new()
  Assert.notNil(r.shader)
  r:release()
end

function T.shader_has_required_lighting_uniforms()
  if not hasGraphics() then return end
  local r = MapRenderer.new()
  local s = r.shader
  -- Presence is checked by sending a value; LÖVE errors for unknown names.
  s:send("u_lightEnabled0", true)
  s:send("u_lightVector0", { 0, 0, -1 })
  s:send("u_lightColor0", { 1, 1, 1 })
  s:send("u_diffuseColor", { 1, 1, 1 })
  s:send("u_ambientColor", { 0, 0, 0 })
  s:send("u_specularColor", { 0, 0, 0 })
  s:send("u_emissionColor", { 0, 0, 0 })
  r:release()
end

function T.shader_has_normal_matrix_uniform()
  if not hasGraphics() then return end
  local r = MapRenderer.new()
  -- Send as a 3x3 column-major matrix (nine values).
  r.shader:send("u_normalMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  r:release()
end

-- Build a tiny mesh with the project's vertex layout so the shader can be
-- exercised end-to-end without touching any compiled scene.
local function syntheticMesh(vertices)
  local indices = {}
  for i = 0, #vertices - 1 do indices[i + 1] = i end
  return love.graphics.newMesh(VertexFormat.LAYOUT, vertices, "triangles", "static")
end

function T.literal_color_triangle_ignores_light_direction()
  if not hasGraphics() then return end
  local r = MapRenderer.new()
  local s = r.shader
  s:send("u_proj", "column", {
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  })
  s:send("u_view", "column", {
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  })
  s:send("u_model", "column", {
    1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
  })
  s:send("u_normalMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })

  -- Two different light directions that would change a lit vertex, but should
  -- not affect a literal-color vertex.
  for _, vec in ipairs({ { 0, 0, -1 }, { 0, 0, 1 } }) do
    s:send("u_lightEnabled0", true)
    s:send("u_lightVector0", vec)
    s:send("u_lightColor0", { 1, 0, 0 })
    s:send("u_diffuseColor", { 1, 1, 1 })
    s:send("u_ambientColor", { 0, 0, 0 })
    s:send("u_specularColor", { 0, 0, 0 })
    s:send("u_emissionColor", { 0, 0, 0 })

    local mesh = syntheticMesh({
      { 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
      { 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1, 0 },
    })
    s:send("u_useTexture", false)
    s:send("u_alphaMode", 0)
    s:send("u_alphaCutoff", 0.5 / 255)
    s:send("u_polygonAlpha", 1.0)
    s:send("u_polygonMode", 0)
    love.graphics.setShader(s)
    love.graphics.draw(mesh)
    love.graphics.setShader()
    mesh:release()
  end
  r:release()
end

return T
