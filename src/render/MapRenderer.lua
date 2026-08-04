-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, and runs four passes:
-- opaque (depth write on), cutout (depth write on, shader discards alpha-zero
-- fragments), translucent (depth test on, write governed by polygon bit 11),
-- and wireframe edges. It clears the depth buffer itself (love's frame clear
-- only touches color) and restores every GPU state it changed so the diagnostic
-- UI drawn afterwards is unaffected. It builds no meshes or textures and reads
-- no ROM/NARC data -- those belong to the loader and compiler; here everything
-- is already resident.

local RenderQueue = require("src.render.RenderQueue")
local Matrix3 = require("src.render.Matrix3")
local FieldLightProfile = require("src.data.FieldLightProfile")

local MapRenderer = {}
MapRenderer.__index = MapRenderer

local SHADER_PATH = "src/render/shaders/map.glsl"

-- Epsilon for the DS fragment alpha contract: a 5-bit alpha of zero becomes a
-- normalized value just below half of one 8-bit step.
local CUTOUT_EPSILON = 0.5 / 255

-- App background color; the scene canvas is cleared to it so the final blit
-- matches the previous direct-to-screen output exactly.
local BG_COLOR = { 0.08, 0.09, 0.12, 1 }

function MapRenderer.new()
  return setmetatable({
    shader = love.graphics.newShader(SHADER_PATH),
    stats = { drawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
  }, MapRenderer)
end

function MapRenderer:_releaseCanvases()
  if self.sceneColor then self.sceneColor:release() end
  if self.depth then self.depth:release() end
  self.sceneColor, self.depth = nil, nil
  self.canvasW, self.canvasH = nil, nil
end

function MapRenderer:_ensureCanvases(w, h)
  if self.sceneColor and self.canvasW == w and self.canvasH == h then return end
  self:_releaseCanvases()
  self.sceneColor = love.graphics.newCanvas(w, h)
  self.depth = love.graphics.newCanvas(w, h, { format = "depth24stencil8", readable = false })
  self.canvasW, self.canvasH = w, h
end

local function alphaModeId(alphaClass)
  if alphaClass == "cutout" then return 1 end
  if alphaClass == "translucent" then return 2 end
  return 0 -- opaque / wireframe (wireframe is drawn separately)
end

local function rgb555ToFloat3(packed)
  local r = (packed % 32) / 31.0
  local g = (math.floor(packed / 32) % 32) / 31.0
  local b = (math.floor(packed / 1024) % 32) / 31.0
  return { r, g, b }
end

local function fx12ToFloat3(vec)
  return { vec[1] / 4096.0, vec[2] / 4096.0, vec[3] / 4096.0 }
end

-- Select the active profile record and bind all lighting uniforms.
function MapRenderer:_sendLighting(runtime)
  local profile = runtime.lighting
  if not profile or not profile.records then return end

  local record = FieldLightProfile.select(profile, runtime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
  local shader = self.shader

  for i = 1, 4 do
    local light = record.lights[i]
    shader:send("u_lightEnabled" .. (i - 1), light and light.enabled or false)
    if light then
      shader:send("u_lightVector" .. (i - 1), fx12ToFloat3(light.vectorFx12))
      shader:send("u_lightColor" .. (i - 1), rgb555ToFloat3(light.colorRgb555))
    else
      shader:send("u_lightVector" .. (i - 1), { 0, 0, 0 })
      shader:send("u_lightColor" .. (i - 1), { 0, 0, 0 })
    end
  end

  shader:send("u_diffuseColor", rgb555ToFloat3(record.diffuseRgb555))
  shader:send("u_ambientColor", rgb555ToFloat3(record.ambientRgb555))
  shader:send("u_specularColor", rgb555ToFloat3(record.specularRgb555))
  shader:send("u_emissionColor", rgb555ToFloat3(record.emissionRgb555))

  return record
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
function MapRenderer:_drawItem(item, viewMatrix)
  local mat = item.material
  local shader = self.shader
  local normalMatrix = Matrix3.normalMatrix(item.transform, viewMatrix)

  shader:send("u_model", "column", item.transform)
  shader:send("u_normalMatrix", "column", normalMatrix)

  if mat and mat.image then
    shader:send("u_useTexture", true)
    item.mesh:setTexture(mat.image)
  else
    shader:send("u_useTexture", false)
    item.mesh:setTexture()
  end

  shader:send("u_alphaMode", alphaModeId(item.alphaClass or "opaque"))
  shader:send("u_alphaCutoff", item.alphaCutoff or CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", item.polygonAlpha or 1.0)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  love.graphics.setMeshCullMode(item.cullMode or "back")
  love.graphics.draw(item.mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon.
function MapRenderer:_drawWireframe(item, viewMatrix)
  local lg = love.graphics
  local shader = self.shader
  local normalMatrix = Matrix3.normalMatrix(item.transform, viewMatrix)

  lg.setShader(shader)
  lg.setDepthMode("less", true)
  lg.setBlendMode("alpha")
  shader:send("u_model", "column", item.transform)
  shader:send("u_normalMatrix", "column", normalMatrix)
  shader:send("u_useTexture", false)
  shader:send("u_alphaMode", 0)
  shader:send("u_alphaCutoff", CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", 1.0)
  shader:send("u_polygonMode", 0)
  item.mesh:setTexture()
  love.graphics.setMeshCullMode(item.cullMode or "back")
  lg.setWireframe(true)
  lg.draw(item.mesh)
  lg.setWireframe(false)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- `overlays` is an optional list of opaque diagnostic draw items (player prism,
-- anchor pins) rendered in the opaque pass so they depth-sort against the scene.
function MapRenderer:draw(runtime, camera, overlays)
  local lg = love.graphics
  local all = {}
  for _, d in ipairs(runtime.mapDraws) do all[#all + 1] = d end
  for _, d in ipairs(runtime.buildingDraws) do all[#all + 1] = d end
  for _, d in ipairs(overlays or {}) do all[#all + 1] = d end

  self.stats = {
    drawCalls = 0,
    triangles = runtime.stats.triangleCount,
    meshCount = runtime.stats.meshCount,
    textureCount = runtime.stats.textureCount,
  }

  local w, h = lg.getWidth(), lg.getHeight()
  self:_ensureCanvases(w, h)

  local viewMatrix = camera:view()
  local function doDraw()
    lg.setCanvas({ self.sceneColor, depthstencil = self.depth })
    lg.clear(BG_COLOR, false, true) -- color + depth; love already cleared the screen
    lg.setShader(self.shader)
    self.shader:send("u_proj", "column", camera:projection())
    self.shader:send("u_view", "column", viewMatrix)

    local activeRecord = self:_sendLighting(runtime)
    local queue = RenderQueue.build(all, viewMatrix)

    -- Pass 1: opaque, depth test + write.
    lg.setDepthMode("less", true)
    lg.setBlendMode("alpha")
    for _, d in ipairs(queue.opaque) do self:_drawItem(d, viewMatrix) end

    -- Pass 2: cutout, depth test + write, shader discards alpha-zero fragments.
    for _, d in ipairs(queue.cutout) do self:_drawItem(d, viewMatrix) end

    -- Pass 3: blended, depth test on, write governed by polygon state.
    for _, d in ipairs(queue.translucent) do
      lg.setDepthMode(d.depthEqual and "lequal" or "less", d.translucentDepthWrite or false)
      lg.setBlendMode("alpha", "alphamultiply")
      self:_drawItem(d, viewMatrix)
    end

    -- Pass 4: wireframe edges (polygon alpha zero).
    lg.setDepthMode("less", true)
    lg.setBlendMode("alpha")
    for _, d in ipairs(queue.wireframe) do self:_drawWireframe(d, viewMatrix) end

    -- Composite the scene canvas back to the screen.
    lg.setCanvas()
    lg.setShader()
    lg.setDepthMode()
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
    lg.draw(self.sceneColor, 0, 0)

    return activeRecord
  end

  local ok, result = pcall(doDraw)

  -- Restore state so the 2D diagnostic UI draws normally even after an error.
  lg.setCanvas()
  lg.setShader()
  lg.setDepthMode()
  lg.setMeshCullMode("none")
  lg.setBlendMode("alpha")
  lg.setWireframe(false)
  lg.setColor(1, 1, 1, 1)

  if not ok then error(result) end
  return result
end

function MapRenderer:release()
  if self.shader then self.shader:release() end
  self.shader = nil
  self:_releaseCanvases()
end

return MapRenderer
