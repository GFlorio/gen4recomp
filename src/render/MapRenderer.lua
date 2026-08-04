-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, and runs the spec's three
-- passes: opaque (depth write on), alpha-mask (depth write on, shader discards
-- below the cutoff so color-zero texels leave no opaque halo), then blended
-- (depth test on, depth write off, back-to-front). It clears the depth buffer
-- itself (love's frame clear only touches color) and restores every GPU state
-- it changed so the diagnostic UI drawn afterwards is unaffected. It builds no
-- meshes or textures and reads no ROM/NARC data -- those belong to the loader
-- and compiler; here everything is already resident.

local MapRenderer = {}
MapRenderer.__index = MapRenderer

local SHADER_PATH = "src/render/shaders/map.glsl"

function MapRenderer.new()
  return setmetatable({
    shader = love.graphics.newShader(SHADER_PATH),
    stats = { drawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
  }, MapRenderer)
end

local function alphaModeId(mode)
  if mode == "mask" then return 1 end
  return 0
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
  shader:send("u_alphaMode", mat and alphaModeId(mat.alphaMode) or 0)
  shader:send("u_alphaCutoff", mat and mat.alphaCutoff or 0.5)
  love.graphics.setMeshCullMode(mat and mat.cullMode or "back")
  love.graphics.draw(item.mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

local function classify(draws)
  local opaque, mask, blend = {}, {}, {}
  for _, d in ipairs(draws) do
    local mode = d.material and d.material.alphaMode or "opaque"
    if mode == "blend" then
      blend[#blend + 1] = d
    elseif mode == "mask" then
      mask[#mask + 1] = d
    else
      opaque[#opaque + 1] = d
    end
  end
  return opaque, mask, blend
end

-- `overlays` is an optional list of opaque diagnostic draw items (player prism,
-- anchor pins) rendered in the opaque pass so they depth-sort against the scene.
function MapRenderer:draw(runtime, camera, overlays)
  local lg = love.graphics
  local all = {}
  for _, d in ipairs(runtime.mapDraws) do all[#all + 1] = d end
  for _, d in ipairs(runtime.buildingDraws) do all[#all + 1] = d end
  local opaque, mask, blend = classify(all)
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

  -- Pass 2: alpha-mask, depth test + write, shader discards below cutoff.
  for _, d in ipairs(mask) do self:_drawItem(d) end

  -- Pass 3: blended, depth test on, write off (Elm has none; correct for later).
  lg.setDepthMode("less", false)
  for _, d in ipairs(blend) do self:_drawItem(d) end

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
