-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, resolves each billboard draw
-- against the frame's camera through BillboardTransform, and runs four passes:
-- opaque (depth write on), cutout (depth write on, shader discards alpha-zero
-- fragments), translucent (depth test on, write governed by polygon bit 11),
-- and wireframe edges. Opaque, cutout, and wireframe passes additionally stamp
-- their polygon ID and depth into a second render target that the DS
-- edge-marking post-process reads when compositing to the screen; the
-- translucent pass deliberately leaves that target alone. It clears the depth
-- buffer itself (love's frame clear only touches color) and restores the exact
-- caller state it changed (canvas, shader, depth, cull, blend, wireframe,
-- color) even when drawing raises, so the diagnostic UI drawn afterwards is
-- unaffected. Resource construction is transactional: a failed shader or
-- canvas allocation releases everything already created, and a canvas
-- recreation keeps the previous target set usable until the replacement is
-- complete. It builds no meshes or textures and reads no ROM/NARC data --
-- those belong to the loader and compiler; here everything is already
-- resident.

local RenderQueue = require("libs.engine.src.RenderQueue")
local BillboardTransform = require("libs.engine.src.BillboardTransform")
local Matrix3 = require("libs.math.src.Matrix3")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local DsLighting = require("libs.engine.src.DsLighting")

---@class MapRenderer
---@field _graphics love.Graphics
---@field shader love.Shader
---@field edgeShader love.Shader
---@field edgeColors table<integer, number[]>
---@field edgeAlpha number
---@field stats { drawCalls: integer, triangles: integer, meshCount: integer, textureCount: integer }
---@field sceneColor love.Canvas?
---@field idDepth love.Canvas?
---@field depth love.Canvas?
---@field canvasW integer?
---@field canvasH integer?
local MapRenderer = {}
MapRenderer.__index = MapRenderer

-- Shader sources are engine assets colocated with this module, addressed by
-- repo-relative path -- the same namespace as every `require`. They are read
-- through the LÖVE resource boundary: love.filesystem resolves the paths from
-- the archive root when the game ships as a .love or fused executable, and
-- in the repo checkout, where the app runs as `love game/` and the engine
-- tree sits outside that source mount, from the host file under the source
-- base directory. `opts.readSource` injects the reader so construction is
-- testable headless without any filesystem.
local SHADER_SOURCE_PATHS = {
  map = "libs/engine/src/shaders/map.glsl",
  edge = "libs/engine/src/shaders/edge.glsl",
}

---@param path string
---@return string
local function defaultReadSource(path)
  if love and love.filesystem then
    local source = love.filesystem.read(path)
    if source then
      return source
    end
    local base = love.filesystem.getSourceBaseDirectory()
    local f = io.open(base .. "/" .. path, "rb")
    if f then
      local src = f:read("*a")
      f:close()
      return src
    end
  end
  error("cannot read shader source: " .. path)
end

-- Epsilon for the DS fragment alpha contract: a 5-bit alpha of zero becomes a
-- normalized value just below half of one 8-bit step.
local CUTOUT_EPSILON = 0.5 / 255

-- App background color; the scene canvas is cleared to it so the final blit
-- matches the previous direct-to-screen output exactly.
local BG_COLOR = { 0.08, 0.09, 0.12, 1 }

-- Rear-plane entry for the polygon-ID/depth target: the rear-plane sentinel
-- (MapRenderer.REAR_PLANE_ID) at a depth beyond the far plane. The green
-- channel holds linear eye-space depth, so the rear plane must clear to a
-- large value for background neighbours to read as farther than any geometry --
-- that is what outlines silhouettes against the background (GBATEK: at the
-- screen borders edges are resolved against the rear plane's polygon_id).
local ID_CLEAR = { 1, 1e9, 0, 1 }

-- DS framebuffer height. Edge marking is one hardware pixel wide, so the
-- post-process samples that many framebuffer pixels out to keep the outline at
-- its DS-relative weight instead of thinning as the window grows.
local DS_NATIVE_HEIGHT = 192
local MAX_EDGE_RADIUS = 8

-- Polygon-ID domain (GBATEK POLYGON_ATTR polygon ID, 6-bit 0..63) and the
-- sentinels stamped into the ID/depth target: 254 marks translucent fragments
-- (clear of the real IDs and of the rear plane), 255 is the rear plane and the
-- wireframe pass. The shader normalizes by the rear-plane value (id/255;
-- map.glsl documents it).
MapRenderer.MAX_POLYGON_ID = 63
MapRenderer.REAR_PLANE_ID = 255

-- Polygon ID stamped into the ID/depth target by translucent fragments. It makes
-- translucent geometry OCCLUDE the opaque geometry behind it for edge marking --
-- so a back object is no longer outlined through a translucent object in front of
-- it -- while telling the edge pass never to outline the translucent pixel itself
-- (GBATEK: edge marking is applied to opaque and wireframe polygons only). 254
-- stays clear of the real 6-bit IDs (0-63) and the 255 rear-plane/wireframe id.
local TRANSLUCENT_SENTINEL_ID = 254

---@param opts { edgeMarking?: { colors?: number[][], alpha?: number }, graphics?: love.Graphics, readSource?: fun(path: string): string }?
function MapRenderer.new(opts)
  opts = opts or {}
  local edgeMarking = opts.edgeMarking or {}
  local colors = edgeMarking.colors
  if not colors then
    colors = {}
    for i = 1, 8 do
      colors[i] = { 0.16, 0.16, 0.16 }
    end
  end
  assert(#colors == 8, "edgeMarking.colors must have 8 entries")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics, "MapRenderer requires a graphics context")
  local readSource = opts.readSource or defaultReadSource
  local renderer = setmetatable({
    _graphics = graphics,
    edgeColors = colors,
    edgeAlpha = edgeMarking.alpha or 0.5,
    stats = { drawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
  }, MapRenderer)
  -- Shader construction is transactional: a failure while creating the second
  -- shader (or reading its source) releases the first (and any other
  -- already-created resource) before the error propagates, so a failed
  -- renderer never leaks GPU resources.
  local ok, err = pcall(function()
    renderer.shader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.map))
    renderer.edgeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.edge))
  end)
  if not ok then
    renderer:release()
    error(err)
  end
  return renderer
end

function MapRenderer:_releaseCanvases()
  if self.sceneColor then
    self.sceneColor:release()
  end
  if self.idDepth then
    self.idDepth:release()
  end
  if self.depth then
    self.depth:release()
  end
  self.sceneColor, self.idDepth, self.depth = nil, nil, nil
  self.canvasW, self.canvasH = nil, nil
end

-- Recreate the render targets at a new size. The replacement set is built
-- fully before the live one is released: a failed allocation releases only
-- the partial new canvases and leaves the previous targets and their recorded
-- size in place, so the renderer keeps working at the old size.
function MapRenderer:_ensureCanvases(w, h)
  if self.sceneColor and self.canvasW == w and self.canvasH == h then
    return
  end
  local lg = assert(self._graphics)
  local sceneColor, idDepth, depth
  local ok, err = pcall(function()
    sceneColor = lg.newCanvas(w, h)
    -- Red holds the normalized polygon ID, green the linear eye-space depth in
    -- world units. The format must be 32-bit float: the depth spans the full near
    -- to far range (hundreds of units) and edge marking tests sub-unit steps
    -- against it, which 16-bit floats cannot resolve across that range.
    idDepth = lg.newCanvas(w, h, { format = "rg32f" })
    idDepth:setFilter("nearest", "nearest")
    depth = lg.newCanvas(w, h, { format = "depth24stencil8", readable = false })
  end)
  if not ok then
    if sceneColor then
      sceneColor:release()
    end
    if idDepth then
      idDepth:release()
    end
    if depth then
      depth:release()
    end
    error(err)
  end
  self:_releaseCanvases()
  self.sceneColor, self.idDepth, self.depth = sceneColor, idDepth, depth
  self.canvasW, self.canvasH = w, h
end

-- Field cameras have an authored, immutable distance. DS-pixel effects scale
-- only with viewport height.
function MapRenderer.fieldEdgeRadiusPixels(viewportHeight)
  return math.max(1, math.min(MAX_EDGE_RADIUS, math.floor(viewportHeight / DS_NATIVE_HEIGHT + 0.5)))
end

local function alphaModeId(alphaClass)
  if alphaClass == "cutout" then
    return 1
  end
  if alphaClass == "translucent" then
    return 2
  end
  return 0 -- opaque / wireframe (wireframe is drawn separately)
end

-- Decode a polygon's 4-bit light mask (GBATEK POLYGON_ATTR bits 0-3) into the
-- compact per-draw u_lightMask uniform: one 0/1 float per light. The shader
-- gates each profile light with its component, so a polygon only receives the
-- lights its mask admits -- the global profile enabled state alone is not
-- enough. LÖVE's GLSL version has no integer bitwise operators, so the decode
-- happens here once per draw instead.
function MapRenderer.lightMaskUniforms(mask)
  local m = mask or 0
  assert(m >= 0 and m <= 15 and m % 1 == 0, "light mask must be a 4-bit integer, got " .. tostring(mask))
  return {
    m % 2 >= 1 and 1.0 or 0.0,
    m % 4 >= 2 and 1.0 or 0.0,
    m % 8 >= 4 and 1.0 or 0.0,
    m % 16 >= 8 and 1.0 or 0.0,
  }
end

local function rgb555ToFloat3(packed)
  local r = (packed % 32) / DsLighting.RGB5_MAX
  local g = (math.floor(packed / 32) % 32) / DsLighting.RGB5_MAX
  local b = (math.floor(packed / 1024) % 32) / DsLighting.RGB5_MAX
  return { r, g, b }
end

local function fx12ToFloat3(vec)
  return { vec[1] / DsLighting.FX12_SCALE, vec[2] / DsLighting.FX12_SCALE, vec[3] / DsLighting.FX12_SCALE }
end

-- Select the active profile record and bind all lighting uniforms. A runtime
-- with no lighting profile still gets the disabled/default state sent
-- explicitly: an unlit scene must not inherit lights or material colors from
-- a lit scene drawn earlier with the same renderer. (u_lightMask needs no
-- reset: every draw path sends it before drawing.)
function MapRenderer:_sendLighting(runtime)
  local shader = self.shader
  local profile = runtime.lighting
  if not profile or not profile.records then
    for i = 0, 3 do
      shader:send("u_lightEnabled" .. i, false)
      shader:send("u_lightVector" .. i, { 0, 0, 0 })
      shader:send("u_lightColor" .. i, { 0, 0, 0 })
    end
    shader:send("u_diffuseColor", { 0, 0, 0 })
    shader:send("u_ambientColor", { 0, 0, 0 })
    shader:send("u_specularColor", { 0, 0, 0 })
    shader:send("u_emissionColor", { 0, 0, 0 })
    return
  end

  local record = FieldLightProfile.select(profile, runtime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)

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
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
-- `projection` is per item: billboard actors draw through the camera's
-- field-billboard projection, everything else through the world projection.
function MapRenderer:_drawItem(item, viewMatrix, polygonIdOverride, projection)
  local lg = assert(self._graphics)
  local mat = item.material
  local shader = self.shader
  local normalMatrix = Matrix3.normalMatrix(item.transform, viewMatrix)

  shader:send("u_proj", "column", projection)
  shader:send("u_model", "column", item.transform)
  shader:send("u_normalMatrix", "column", normalMatrix)

  if mat and mat.image then
    shader:send("u_useTexture", true)
    item.mesh:setTexture(mat.image)
  else
    shader:send("u_useTexture", false)
    item.mesh:setTexture()
  end

  shader:send("u_alphaMode", alphaModeId(RenderQueue.effectiveAlphaClass(item)))
  shader:send("u_alphaCutoff", item.alphaCutoff or CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", item.polygonAlpha or 1.0)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  shader:send("u_polygonId", polygonIdOverride or (item.polygonId or 0) / MapRenderer.REAR_PLANE_ID)
  shader:send("u_lightMask", MapRenderer.lightMaskUniforms(item.lightMask))
  lg.setMeshCullMode(item.cullMode or "back")
  lg.draw(item.mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon.
function MapRenderer:_drawWireframe(item, viewMatrix, projection)
  local lg = assert(self._graphics)
  local shader = self.shader
  local normalMatrix = Matrix3.normalMatrix(item.transform, viewMatrix)

  lg.setShader(shader)
  lg.setDepthMode("less", true)
  lg.setBlendMode("alpha")
  shader:send("u_proj", "column", projection)
  shader:send("u_model", "column", item.transform)
  shader:send("u_normalMatrix", "column", normalMatrix)
  shader:send("u_useTexture", false)
  shader:send("u_alphaMode", 0)
  shader:send("u_alphaCutoff", CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", 1.0)
  shader:send("u_polygonMode", 0)
  -- Wireframe polygons stamp the rear-plane sentinel, normalized by the id
  -- domain exactly like every other id (255/255 == 1.0).
  shader:send("u_polygonId", MapRenderer.REAR_PLANE_ID / MapRenderer.REAR_PLANE_ID)
  shader:send("u_lightMask", MapRenderer.lightMaskUniforms(item.lightMask))
  item.mesh:setTexture()
  lg.setMeshCullMode(item.cullMode or "back")
  lg.setWireframe(true)
  lg.draw(item.mesh)
  lg.setWireframe(false)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- `worldDraws` is the flattened scene draw list -- map geometry, building
-- batches, the neighbour ring, and actors -- already numbered with submission
-- indices in desired source order by SceneAssembly; the renderer draws exactly
-- this list and no other scene state. `alpha` is the render interpolation
-- factor forwarded to the camera so the scene is viewed from the same smoothed
-- state the actors render at. FieldViewport limits the render-target size and
-- places the result inside the host drawable.
function MapRenderer:draw(runtime, camera, worldDraws, viewport, alpha)
  assert(viewport and viewport.worldViewport, "MapRenderer requires a FieldViewport")
  local lg = assert(self._graphics)
  local draws = worldDraws or {}

  self.stats = {
    drawCalls = 0,
    triangles = runtime.stats.triangleCount,
    meshCount = runtime.stats.meshCount,
    textureCount = runtime.stats.textureCount,
  }

  local rectangle = viewport.worldViewport
  local w = math.max(1, math.floor(rectangle.width + 0.5))
  local h = math.max(1, math.floor(rectangle.height + 0.5))
  self:_ensureCanvases(w, h)

  local viewMatrix = camera:view(alpha)

  -- Billboard draws own no baked matrix: resolve each one against this frame's
  -- camera before anything reads `transform`, so u_model, the normal matrix,
  -- translucent sorting, and every pass all use the same orientation.
  for _, d in ipairs(draws) do
    if d.billboardBase then
      d.transform = BillboardTransform.resolve(d.billboardBase, viewMatrix)
    end
  end

  -- Two projections, computed once per frame: the world projection and the
  -- depth-biased billboard copy (see FieldCamera:billboardProjection). Only
  -- actor billboards opt into the biased matrix; map/building billboards and
  -- static-model actors keep the world projection, as on the DS.
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()

  local function projectionFor(item)
    return item.billboardProjection and billboardProjection or worldProjection
  end

  local sceneTargets = { self.sceneColor, self.idDepth, depthstencil = self.depth }

  local function doDraw()
    lg.setCanvas(sceneTargets)
    lg.clear(BG_COLOR, ID_CLEAR, false, true)
    lg.setShader(self.shader)
    lg.setDepthMode("less", true)
    lg.setBlendMode("alpha")
    self.shader:send("u_view", "column", viewMatrix)

    self:_sendLighting(runtime)
    local queue = RenderQueue.build(draws, viewMatrix)

    -- Pass 1: opaque, depth test + write.
    for _, d in ipairs(queue.opaque) do
      self:_drawItem(d, viewMatrix, nil, projectionFor(d))
    end

    -- Pass 2: cutout, depth test + write, shader discards alpha-zero fragments.
    for _, d in ipairs(queue.cutout) do
      self:_drawItem(d, viewMatrix, nil, projectionFor(d))
    end

    -- Pass 3: blended, depth test on, write governed by polygon state. The
    -- ID/depth target stays bound so translucent fragments occlude the opaque
    -- geometry behind them for edge marking; they stamp a sentinel ID so the
    -- edge pass never outlines them. The ID/depth attachment carries alpha 1,
    -- so it is replaced -- not alpha-blended -- even while the colour
    -- attachment blends.
    for _, d in ipairs(queue.translucent) do
      lg.setDepthMode(d.depthEqual and "lequal" or "less", d.translucentDepthWrite or false)
      lg.setBlendMode("alpha", "alphamultiply")
      self:_drawItem(d, viewMatrix, TRANSLUCENT_SENTINEL_ID / MapRenderer.REAR_PLANE_ID, projectionFor(d))
    end

    -- Pass 4: wireframe edges (polygon alpha zero). These count as opaque for
    -- edge marking and write their real polygon ID into the ID target.
    lg.setCanvas(sceneTargets)
    for _, d in ipairs(queue.wireframe) do
      self:_drawWireframe(d, viewMatrix, projectionFor(d))
    end

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
    self.edgeShader:send("u_edgeRadius", MapRenderer.fieldEdgeRadiusPixels(h))
    lg.draw(self.sceneColor, rectangle.x, rectangle.y, 0, rectangle.width / w, rectangle.height / h)
    lg.setShader()
  end

  -- Capture every caller state the draw modifies, restore the captured values
  -- afterwards -- on success and error alike -- and rethrow the original draw
  -- error. The 2D diagnostic UI after the scene must never inherit the
  -- scene's canvas, shader, depth, cull, blend, wireframe, or color state.
  local canvas = lg.getCanvas()
  local shader = lg.getShader()
  local blendMode, blendAlpha = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local cullMode = lg.getMeshCullMode()
  local wireframe = lg.isWireframe()
  local color = { lg.getColor() }

  local ok, err = pcall(doDraw)

  lg.setCanvas(canvas)
  lg.setShader(shader)
  lg.setBlendMode(blendMode, blendAlpha)
  lg.setDepthMode(depthMode, depthWrite)
  lg.setWireframe(wireframe)
  lg.setMeshCullMode(cullMode)
  lg.setColor(color[1], color[2], color[3], color[4])

  if not ok then
    error(err)
  end
end

function MapRenderer:release()
  if self.shader then
    self.shader:release()
  end
  if self.edgeShader then
    self.edgeShader:release()
  end
  self.shader, self.edgeShader = nil, nil
  self:_releaseCanvases()
end

return MapRenderer
