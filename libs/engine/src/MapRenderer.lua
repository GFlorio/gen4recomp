-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, and runs four passes:
-- opaque (depth write on), cutout (depth write on, shader discards alpha-zero
-- fragments), translucent (depth test on, write governed by polygon bit 11),
-- and wireframe edges. Opaque, cutout, and wireframe passes additionally stamp
-- their polygon ID and depth into a second render target that the DS
-- edge-marking post-process reads when compositing to the screen; the
-- translucent pass deliberately leaves that target alone. It clears the depth
-- buffer itself (love's frame clear only touches color) and restores every GPU
-- state it changed so the diagnostic UI drawn afterwards is unaffected. It
-- builds no meshes or textures and reads no ROM/NARC data -- those belong to
-- the loader and compiler; here everything is already resident.

local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix3 = require("libs.engine.src.Matrix3")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")

local MapRenderer = {}
MapRenderer.__index = MapRenderer

-- Shaders are engine assets colocated with this module. Resolve them relative
-- to this file (not the LÖVE source root or cwd) so the renderer loads its own
-- bundled GLSL regardless of which app mounts the engine.
local MODULE_DIR = (debug.getinfo(1, "S").source:match("^@(.*[/\\])")) or "./"
local SHADER_PATH = MODULE_DIR .. "shaders/map.glsl"
local EDGE_SHADER_PATH = MODULE_DIR .. "shaders/edge.glsl"

local function loadShaderSource(path)
  local f = assert(io.open(path, "r"), "cannot open shader: " .. path)
  local src = f:read("*a")
  f:close()
  return src
end

-- Epsilon for the DS fragment alpha contract: a 5-bit alpha of zero becomes a
-- normalized value just below half of one 8-bit step.
local CUTOUT_EPSILON = 0.5 / 255

-- App background color; the scene canvas is cleared to it so the final blit
-- matches the previous direct-to-screen output exactly.
local BG_COLOR = { 0.08, 0.09, 0.12, 1 }

-- Rear-plane entry for the polygon-ID/depth target: the sentinel ID 255 at a
-- depth beyond the far plane. The green channel holds linear eye-space depth, so
-- the rear plane must clear to a large value for background neighbours to read as
-- farther than any geometry -- that is what outlines silhouettes against the
-- background (GBATEK: at the screen borders edges are resolved against the rear
-- plane's polygon_id).
local ID_CLEAR = { 1, 1e9, 0, 1 }

-- DS framebuffer height. Edge marking is one hardware pixel wide, so the
-- post-process samples that many framebuffer pixels out to keep the outline at
-- its DS-relative weight instead of thinning as the window grows.
local DS_NATIVE_HEIGHT = 192
local MAX_EDGE_RADIUS = 8

-- Polygon ID stamped into the ID/depth target by translucent fragments. It makes
-- translucent geometry OCCLUDE the opaque geometry behind it for edge marking --
-- so a back object is no longer outlined through a translucent object in front of
-- it -- while telling the edge pass never to outline the translucent pixel itself
-- (GBATEK: edge marking is applied to opaque and wireframe polygons only). 254
-- stays clear of the real 6-bit IDs (0-63) and the 255 rear-plane/wireframe id.
local TRANSLUCENT_SENTINEL_ID = 254

-- Orbit distance (tile units) at which one DS pixel of outline matches the DS
-- framing. Perspective on-screen size scales as 1/distance, so a fixed-pixel
-- outline drifts as the camera zooms; scaling the radius by REFERENCE/distance
-- holds the outline's world-relative weight steady at every zoom. Same lens, so
-- the field of view cancels and only the distance ratio remains.
local REFERENCE_DISTANCE = 26

function MapRenderer.new(opts)
  opts = opts or {}
  local em = opts.edgeMarking or {}
  local colors = em.colors
  if not colors then
    colors = {}
    for i = 1, 8 do colors[i] = { 0.16, 0.16, 0.16 } end
  end
  assert(#colors == 8, "edgeMarking.colors must have 8 entries")
  return setmetatable({
    shader = love.graphics.newShader(loadShaderSource(SHADER_PATH)),
    edgeShader = love.graphics.newShader(loadShaderSource(EDGE_SHADER_PATH)),
    edgeColors = colors,
    edgeAlpha = em.alpha or 0.5,
    stats = { drawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
  }, MapRenderer)
end

function MapRenderer:_releaseCanvases()
  if self.sceneColor then self.sceneColor:release() end
  if self.idDepth then self.idDepth:release() end
  if self.depth then self.depth:release() end
  self.sceneColor, self.idDepth, self.depth = nil, nil, nil
  self.canvasW, self.canvasH = nil, nil
end

function MapRenderer:_ensureCanvases(w, h)
  if self.sceneColor and self.canvasW == w and self.canvasH == h then return end
  self:_releaseCanvases()
  self.sceneColor = love.graphics.newCanvas(w, h)
  -- Red holds the normalized polygon ID, green the linear eye-space depth in
  -- world units. The format must be 32-bit float: the depth spans the full near
  -- to far range (hundreds of units) and edge marking tests sub-unit steps
  -- against it, which 16-bit floats cannot resolve across that range.
  self.idDepth = love.graphics.newCanvas(w, h, { format = "rg32f" })
  self.idDepth:setFilter("nearest", "nearest")
  self.depth = love.graphics.newCanvas(w, h, { format = "depth24stencil8", readable = false })
  self.canvasW, self.canvasH = w, h
end

-- Outline radius in framebuffer pixels: DS-relative screen weight (h/192) times
-- the zoom correction (REFERENCE_DISTANCE/distance) that keeps it constant in
-- world terms across zoom. Clamped to the shader's loop bound.
local function edgeRadius(h, distance)
  local scale = (h / DS_NATIVE_HEIGHT) * (REFERENCE_DISTANCE / distance)
  return math.max(1, math.min(MAX_EDGE_RADIUS, math.floor(scale + 0.5)))
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
function MapRenderer:_drawItem(item, viewMatrix, polygonIdOverride)
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
  shader:send("u_polygonId", polygonIdOverride or (item.polygonId or 255) / 255)
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
  shader:send("u_polygonId", 1.0)
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
  local sceneTargets = { self.sceneColor, self.idDepth, depthstencil = self.depth }

  local function doDraw()
    lg.setCanvas(sceneTargets)
    lg.clear(BG_COLOR, ID_CLEAR, false, true)
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

    -- Pass 3: blended, depth test on, write governed by polygon state. The
    -- ID/depth target stays bound so translucent fragments occlude the opaque
    -- geometry behind them for edge marking; they stamp a sentinel ID so the edge
    -- pass never outlines them. The ID/depth attachment carries alpha 1, so it is
    -- replaced -- not alpha-blended -- even while the colour attachment blends.
    for _, d in ipairs(queue.translucent) do
      lg.setDepthMode(d.depthEqual and "lequal" or "less", d.translucentDepthWrite or false)
      lg.setBlendMode("alpha", "alphamultiply")
      self:_drawItem(d, viewMatrix, TRANSLUCENT_SENTINEL_ID / 255)
    end

    -- Pass 4: wireframe edges (polygon alpha zero). These count as opaque for
    -- edge marking and write their real polygon ID into the ID target.
    lg.setCanvas(sceneTargets)
    lg.setDepthMode("less", true)
    lg.setBlendMode("alpha")
    for _, d in ipairs(queue.wireframe) do self:_drawWireframe(d, viewMatrix) end

    -- Composite the scene canvas back to the screen through the edge shader,
    -- which outlines polygon-ID boundaries that carry a depth step.
    lg.setCanvas()
    lg.setDepthMode()
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
    lg.setShader(self.edgeShader)
    self.edgeShader:send("u_idTex", self.idDepth)
    self.edgeShader:send("u_texelSize", { 1 / w, 1 / h })
    self.edgeShader:send("u_edgeColors", unpack(self.edgeColors))
    self.edgeShader:send("u_edgeAlpha", self.edgeAlpha)
    self.edgeShader:send("u_edgeRadius", edgeRadius(h, camera.distance))
    lg.draw(self.sceneColor, 0, 0)
    lg.setShader()

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
  if self.edgeShader then self.edgeShader:release() end
  self.shader, self.edgeShader = nil, nil
  self:_releaseCanvases()
end

return MapRenderer
