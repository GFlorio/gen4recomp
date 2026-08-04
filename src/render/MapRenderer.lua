-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, and runs four passes:
-- opaque (depth write on), cutout (depth write on, shader discards alpha-zero
-- fragments), translucent (depth test on, write off), and wireframe edges. It
-- clears the depth buffer itself (love's frame clear only touches color) and
-- restores every GPU state it changed so the diagnostic UI drawn afterwards is
-- unaffected. It builds no meshes or textures and reads no ROM/NARC data --
-- those belong to the loader and compiler; here everything is already resident.

local MapRenderer = {}
MapRenderer.__index = MapRenderer

local SHADER_PATH = "src/render/shaders/map.glsl"

-- Epsilon for the DS fragment alpha contract: a 5-bit alpha of zero becomes a
-- normalized value just below half of one 8-bit step.
local CUTOUT_EPSILON = 0.5 / 255

function MapRenderer.new()
  return setmetatable({
    shader = love.graphics.newShader(SHADER_PATH),
    stats = { drawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
  }, MapRenderer)
end

local function alphaModeId(alphaClass)
  if alphaClass == "cutout" then return 1 end
  if alphaClass == "translucent" then return 2 end
  return 0 -- opaque / wireframe (wireframe is drawn separately)
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
function MapRenderer:_drawItem(item)
  local mat = item.material
  local shader = self.shader
  shader:send("u_model", "column", item.transform)
  if mat and mat.image then
    shader:send("u_useTexture", true)
    item.mesh:setTexture(mat.image)
  else
    shader:send("u_useTexture", false)
    item.mesh:setTexture()
  end
  local diffuse = mat and mat.diffuse or { 1, 1, 1, 1 }
  shader:send("u_diffuse", diffuse)
  shader:send("u_alphaMode", alphaModeId(item.alphaClass or (mat and mat.alphaMode) or "opaque"))
  shader:send("u_alphaCutoff", item.alphaCutoff or CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", item.polygonAlpha or 1.0)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  love.graphics.setMeshCullMode(item.cullMode or (mat and mat.cullMode) or "back")
  love.graphics.draw(item.mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

local function classify(draws)
  local opaque, cutout, translucent, wireframe = {}, {}, {}, {}
  for _, d in ipairs(draws) do
    local mode = d.alphaClass or (d.material and d.material.alphaMode) or "opaque"
    if mode == "translucent" then
      translucent[#translucent + 1] = d
    elseif mode == "cutout" then
      cutout[#cutout + 1] = d
    elseif mode == "wireframe" then
      wireframe[#wireframe + 1] = d
    else
      opaque[#opaque + 1] = d
    end
  end
  return opaque, cutout, translucent, wireframe
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon.
function MapRenderer:_drawWireframe(item)
  local lg = love.graphics
  local shader = self.shader
  lg.setShader(shader)
  lg.setDepthMode("less", true)
  lg.setBlendMode("alpha")
  shader:send("u_model", "column", item.transform)
  shader:send("u_useTexture", false)
  shader:send("u_diffuse", { 1, 1, 1, 1 })
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
  local opaque, cutout, translucent, wireframe = classify(all)
  for _, d in ipairs(overlays or {}) do opaque[#opaque + 1] = d end

  self.stats = {
    drawCalls = 0,
    triangles = runtime.stats.triangleCount,
    meshCount = runtime.stats.meshCount,
    textureCount = runtime.stats.textureCount,
  }

  lg.clear(false, false, true) -- clear depth; love already cleared color this frame
  lg.setShader(self.shader)
  self.shader:send("u_proj", "column", camera:projection())
  self.shader:send("u_view", "column", camera:view())

  -- Pass 1: opaque, depth test + write.
  lg.setDepthMode("less", true)
  lg.setBlendMode("alpha")
  for _, d in ipairs(opaque) do self:_drawItem(d) end

  -- Pass 2: cutout, depth test + write, shader discards alpha-zero fragments.
  for _, d in ipairs(cutout) do self:_drawItem(d) end

  -- Pass 3: blended, depth test on, write off.
  lg.setDepthMode("less", false)
  for _, d in ipairs(translucent) do self:_drawItem(d) end

  -- Pass 4: wireframe edges (polygon alpha zero).
  lg.setDepthMode("less", true)
  lg.setBlendMode("alpha")
  for _, d in ipairs(wireframe) do self:_drawWireframe(d) end

  -- Restore state so the 2D diagnostic UI draws normally.
  lg.setShader()
  lg.setDepthMode()
  lg.setMeshCullMode("none")
  lg.setBlendMode("alpha")
  lg.setColor(1, 1, 1, 1)
end

function MapRenderer:release()
  if self.shader then self.shader:release() end
  self.shader = nil
end

return MapRenderer
