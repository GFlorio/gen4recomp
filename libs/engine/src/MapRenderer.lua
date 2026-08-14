-- Draws a loaded runtime scene in real 3D. It owns the shader, the per-frame
-- camera matrices, and the depth/cull/blend state, resolves each billboard draw
-- against the frame's camera through BillboardTransform, and runs four passes:
-- opaque (depth write on), cutout (depth write on, shader discards alpha-zero
-- fragments), translucent (depth test on, write governed by polygon bit 11),
-- and wireframe edges. Opaque, cutout, and wireframe passes additionally stamp
-- their polygon ID and depth into a second render target that the DS
-- edge-marking post-process reads when compositing to the screen (the
-- wireframe pass stamps the rear-plane sentinel, not a real polygon ID); the
-- translucent pass stamps the translucent sentinel there instead, so it
-- occludes opaque geometry behind it for edge marking while the edge pass
-- never outlines the translucent pixels themselves. It clears the depth
-- buffer itself (love's frame clear only touches color) and restores the exact
-- caller state it changed (canvas, shader, depth, cull, blend, wireframe,
-- color) even when drawing raises, so the diagnostic UI drawn afterwards is
-- unaffected. A straddling draw item (the first `leading` vertices submitted
-- under a pre-boundary matrix, per the DS geometry engine) is bent per frame,
-- in the filled passes and the wireframe pass alike: the shared mesh's vertex
-- data is CPU-baked under the two transforms into a scratch mesh drawn with an
-- identity model and released within the frame -- the pool-shared mesh is
-- never mutated. Resource construction is transactional: a failed shader,
-- canvas allocation, or target configuration releases everything already
-- created, and a canvas recreation keeps the previous target set usable until
-- the replacement is complete. It builds no persistent meshes or textures and
-- reads no ROM/NARC data -- those belong to the loader and compiler; here
-- everything is already resident.

local RenderQueue = require("libs.engine.src.RenderQueue")
local BillboardTransform = require("libs.engine.src.BillboardTransform")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local VertexFormat = require("libs.assets.src.VertexFormat")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local FixedPoint = require("libs.math.src.FixedPoint")
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
---@field _sceneTargets { [1]: love.Canvas, [2]: love.Canvas, depthstencil: love.Canvas }?
---@field _lightMaterialColorCache { diffuse: number[], ambient: number[], specular: number[], emission: number[] }
---@field _lightVectorCache number[][]
---@field _lightColorCache number[][]
---@field _queueScratch RenderQueueScratch
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

-- The DS fragment alpha cutoff for cutout draws; the shared render constant
-- (AlphaClassifier.CUTOUT_EPSILON) the model draw path and the neighbor ring
-- reference too.
local CUTOUT_EPSILON = AlphaClassifier.CUTOUT_EPSILON

-- App background color; the scene canvas is cleared to it so the final blit
-- matches the previous direct-to-screen output exactly.
local BG_COLOR = { 0.08, 0.09, 0.12, 1 }
local IDENTITY_MODEL = Matrix4.identity()
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

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
    _lightMaterialColorCache = {
      diffuse = { 0, 0, 0 },
      ambient = { 0, 0, 0 },
      specular = { 0, 0, 0 },
      emission = { 0, 0, 0 },
    },
    _lightVectorCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _lightColorCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _queueScratch = {
      opaque = {},
      cutout = {},
      translucent = {},
      wireframe = {},
      translucentEntries = {},
    },
  }, MapRenderer)
  -- Shader construction is transactional: a failure while creating the second
  -- shader (or reading its source) releases the first (and any other
  -- already-created resource) before the error propagates, so a failed
  -- renderer never leaks GPU resources.
  local ok, err = pcall(function()
    renderer.shader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.map))
    renderer.edgeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.edge))
    renderer.edgeShader:send("u_edgeColors", unpack(renderer.edgeColors))
    renderer.edgeShader:send("u_edgeAlpha", renderer.edgeAlpha)
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
  self._sceneTargets = nil
end

local function sendEdgeTargetUniforms(shader, idDepth, w, h)
  shader:send("u_idTex", idDepth)
  shader:send("u_texelSize", { 1 / w, 1 / h })
  shader:send("u_edgeRadius", MapRenderer.fieldEdgeRadiusPixels(h))
end

-- Recreate the render targets at a new size. The replacement set is allocated
-- and configured before the live one is released. A failed allocation or
-- shader send releases only the staged canvases, restores the previous edge
-- configuration, and leaves the published targets and size in place.
function MapRenderer:_ensureCanvases(w, h)
  if self.sceneColor and self.canvasW == w and self.canvasH == h then
    return
  end
  local lg = assert(self._graphics)
  local sceneColor, idDepth, depth, sceneTargets
  local ok, err = pcall(function()
    sceneColor = lg.newCanvas(w, h)
    -- Red holds the normalized polygon ID, green the linear eye-space depth in
    -- world units. The format must be 32-bit float: the depth spans the full near
    -- to far range (hundreds of units) and edge marking tests sub-unit steps
    -- against it, which 16-bit floats cannot resolve across that range.
    idDepth = lg.newCanvas(w, h, { format = "rg32f" })
    idDepth:setFilter("nearest", "nearest")
    depth = lg.newCanvas(w, h, { format = "depth24stencil8", readable = false })
    sceneTargets = { sceneColor, idDepth, depthstencil = depth }
    sendEdgeTargetUniforms(self.edgeShader, idDepth, w, h)
  end)
  if not ok then
    if self.idDepth then
      pcall(sendEdgeTargetUniforms, self.edgeShader, self.idDepth, self.canvasW, self.canvasH)
    end
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
  self._sceneTargets = sceneTargets
end

-- Field cameras have an authored, immutable distance. DS-pixel effects scale
-- only with viewport height.
function MapRenderer.fieldEdgeRadiusPixels(viewportHeight)
  return math.max(1, math.min(MAX_EDGE_RADIUS, math.floor(viewportHeight / DS_NATIVE_HEIGHT + 0.5)))
end

local function alphaModeId(alphaClass)
  if alphaClass == AlphaClassifier.CUTOUT then
    return 1
  end
  if alphaClass == AlphaClassifier.TRANSLUCENT then
    return 2
  end
  return 0 -- opaque / wireframe (wireframe is drawn separately)
end

-- Decode every polygon 4-bit light mask (GBATEK POLYGON_ATTR bits 0-3) once.
-- The shader gates each profile light with one component, and the renderer
-- treats these shared values as immutable.
local LIGHT_MASK_UNIFORMS = {}
for mask = 0, 15 do
  LIGHT_MASK_UNIFORMS[mask] = {
    mask % 2 >= 1 and 1.0 or 0.0,
    mask % 4 >= 2 and 1.0 or 0.0,
    mask % 8 >= 4 and 1.0 or 0.0,
    mask % 16 >= 8 and 1.0 or 0.0,
  }
end

-- Public validation helper for test-facing/item-construction code. Draw paths
-- index the immutable precomputed mask directly and allocate nothing; callers
-- receive their own copy and cannot mutate that render-path cache.
---@param m integer
---@return number[]
function MapRenderer.lightMaskUniforms(m)
  local uniform = type(m) == "number" and LIGHT_MASK_UNIFORMS[m]
  assert(uniform, "light mask must be a 4-bit integer, got " .. tostring(m))
  return { uniform[1], uniform[2], uniform[3], uniform[4] }
end

local function decodeRgb555(target, packed)
  target[1] = (packed % 32) / FixedPoint.RGB5_MAX
  target[2] = (math.floor(packed / 32) % 32) / FixedPoint.RGB5_MAX
  target[3] = (math.floor(packed / 1024) % 32) / FixedPoint.RGB5_MAX
end

local function decodeFx12(target, vec)
  target[1] = vec[1] / FixedPoint.FX32_SCALE
  target[2] = vec[2] / FixedPoint.FX32_SCALE
  target[3] = vec[3] / FixedPoint.FX32_SCALE
end

local ZERO_COLOR = { 0, 0, 0 }

-- Select the active profile record, bind the light uniforms, and keep the
-- profile's material registers for the per-item composition in _drawMesh /
-- _drawWireframe: the field engine owns every material color channel, so a
-- static item's effective registers are the profile's. A runtime with no
-- lighting profile clears the light uniforms and drops the registers (the
-- per-draw u_mat* sends then reset to zero), so an unlit scene cannot
-- inherit lights or material colors from a lit scene drawn earlier with the
-- same renderer. (u_lightMask needs no reset: every draw path sends it
-- before drawing.)
function MapRenderer:_sendLighting(runtime)
  local shader = self.shader
  local profile = runtime.lighting
  if not profile or not profile.records then
    if not self._lightingLit then
      return
    end
    for i = 0, 3 do
      shader:send("u_lightEnabled" .. i, false)
      shader:send("u_lightVector" .. i, ZERO_COLOR)
      shader:send("u_lightColor" .. i, ZERO_COLOR)
    end
    self._lightingLit = false
    self._lightingProfile = nil
    self._lightingRecord = nil
    self._lightMaterialColors = nil
    return
  end

  local record = FieldLightProfile.select(profile, runtime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
  if self._lightingLit and self._lightingProfile == profile and self._lightingRecord == record then
    return
  end

  local materialColors = self._lightMaterialColorCache
  decodeRgb555(materialColors.diffuse, record.diffuseRgb555)
  decodeRgb555(materialColors.ambient, record.ambientRgb555)
  decodeRgb555(materialColors.specular, record.specularRgb555)
  decodeRgb555(materialColors.emission, record.emissionRgb555)

  for i = 1, 4 do
    local light = record.lights[i]
    local vector = self._lightVectorCache[i]
    local color = self._lightColorCache[i]
    shader:send("u_lightEnabled" .. (i - 1), light and light.enabled or false)
    if light then
      decodeFx12(vector, light.vectorFx12)
      decodeRgb555(color, light.colorRgb555)
    else
      vector[1], vector[2], vector[3] = 0, 0, 0
      color[1], color[2], color[3] = 0, 0, 0
    end
    shader:send("u_lightVector" .. (i - 1), vector)
    shader:send("u_lightColor" .. (i - 1), color)
  end
  self._lightingLit = true
  self._lightingProfile = profile
  self._lightingRecord = record
  self._lightMaterialColors = materialColors
end

-- The effective DS material register for one channel of one draw item: the
-- field profile supplies every channel (the HGSS field policy clears the
-- materials' color ownership, so stored colors alone never reach the DS),
-- except channels a playing NSBMA color clip drives -- the clip replaces
-- the register. With no profile the register resets to zero so a later lit
-- scene cannot inherit stale material colors.
local function effectiveMaterialColor(value, colorsAnimated, profileColor)
  if value ~= nil and colorsAnimated then
    return value
  end
  return profileColor or ZERO_COLOR
end

-- Bake a straddling item's vertex data into world space, exactly as the DS
-- geometry engine transformed each vertex at submission under the
-- then-current matrix: the first `leading` vertices under the straddle
-- transform, the rest under the item transform. Positions transform through
-- the full matrix; normals through the matrix's linear part only (a
-- direction never picks up a translation). UVs, colors, and the color source
-- ride unchanged. `vertices` is a plain table of project-layout vertex
-- records; the returned table is fresh and owned by the caller. Pure
-- arithmetic, no graphics state.
-- A straddle record always splits a segment strictly between zero and its
-- full vertex count; anything else is a corrupted provenance record and
-- fails loudly instead of baking a degenerate bend.
---@param vertices number[][] -- project render layout records: {x,y,z, u,v, nx,ny,nz, r,g,b,a, colorSource}
---@param leading integer
---@param straddleTransform number[]
---@param transform number[]
---@return number[][]
function MapRenderer.bakeStraddle(vertices, leading, straddleTransform, transform)
  assert(type(vertices) == "table" and #vertices > 0, "bakeStraddle requires a non-empty vertex table")
  assert(
    type(leading) == "number" and leading >= 1 and leading < #vertices,
    "bakeStraddle leading count " .. tostring(leading) .. " is out of range for " .. #vertices .. " vertices"
  )
  local leadingNormal = Matrix3.modelNormal(straddleTransform)
  local trailingNormal = Matrix3.modelNormal(transform)
  local baked = {}
  for i, v in ipairs(vertices) do
    local m, nm
    if i <= leading then
      m, nm = straddleTransform, leadingNormal
    else
      m, nm = transform, trailingNormal
    end
    local x, y, z = Matrix4.transformPoint(m, v[1], v[2], v[3])
    local nx, ny, nz = Matrix3.transform(nm, v[6], v[7], v[8])
    baked[i] = { x, y, z, v[4], v[5], nx, ny, nz, v[9], v[10], v[11], v[12], v[13] }
  end
  return baked
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
-- `projection` is per item: billboard actors draw through the camera's
-- field-billboard projection, everything else through the world projection.
-- `modelMatrix`/`modelNormal` are the item's unless the item straddles (a
-- straddling item draws its baked world-space scratch mesh with an identity
-- model). `alphaClass` was selected by the queue pass and is passed through
-- without reclassifying the item.
function MapRenderer:_drawItem(item, polygonIdOverride, projection, alphaClass)
  if item.straddle then
    self:_drawStraddle(item, polygonIdOverride, projection, alphaClass)
    return
  end
  self:_drawMesh(
    item,
    polygonIdOverride,
    projection,
    item.transform,
    assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    alphaClass
  )
end

-- Draw a straddling item: the DS submitted its first `leading` vertices
-- under the pre-boundary matrix, so the renderer CPU-bakes them under
-- item.straddle.transform and the rest under item.transform (per frame --
-- the transforms animate), and draws the result with an identity model. The
-- bake never mutates the pool-shared mesh (the pool dedups geometry by
-- path): a scratch mesh is created, drawn, and released within this call, on
-- the failure path as well as the success path. The scratch carries the
-- source mesh's vertex map, so index order is preserved exactly.
function MapRenderer:_drawStraddle(item, polygonIdOverride, projection, alphaClass)
  local lg = assert(self._graphics)
  local scratch
  local ok, err = pcall(function()
    -- love 11.5 has no Mesh:getVertices bulk read; the CPU-side vertex data
    -- is still reachable per vertex (getVertex returns the attribute
    -- components as multiple values on this build).
    local vertices = {}
    for i = 1, item.mesh:getVertexCount() do
      vertices[i] = { item.mesh:getVertex(i) }
    end
    scratch = lg.newMesh(
      VertexFormat.LAYOUT,
      MapRenderer.bakeStraddle(vertices, item.straddle.leading, item.straddle.transform, item.transform),
      "triangles",
      "static"
    )
    local map = item.mesh:getVertexMap()
    if map and #map > 0 then
      scratch:setVertexMap(map)
    end
    self:_drawMesh(item, polygonIdOverride, projection, IDENTITY_MODEL, IDENTITY_MODEL_NORMAL, scratch, alphaClass)
  end)
  if scratch then
    scratch:release()
  end
  if not ok then
    error(err)
  end
end

-- The common draw body: bind the model/normal matrices, the material's
-- uniforms/texture/cull state, draw the mesh, and count the call.
function MapRenderer:_drawMesh(item, polygonIdOverride, projection, modelMatrix, modelNormal, mesh, alphaClass)
  local lg = assert(self._graphics)
  local mat = item.material
  local shader = self.shader

  shader:send("u_proj", "column", projection)
  shader:send("u_model", "column", modelMatrix)
  shader:send("u_modelNormal", "column", modelNormal)

  -- The effective DS material registers: the field profile's colors, with
  -- any playing NSBMA color clip's sampled colors replacing them (see
  -- effectiveMaterialColor). Static items (no material colors) always get
  -- the profile.
  local profileColors = self._lightMaterialColors
  shader:send(
    "u_matDiffuse",
    effectiveMaterialColor(mat and mat.matDiffuse, mat and mat.colorsAnimated, profileColors and profileColors.diffuse)
  )
  shader:send(
    "u_matAmbient",
    effectiveMaterialColor(mat and mat.matAmbient, mat and mat.colorsAnimated, profileColors and profileColors.ambient)
  )
  shader:send(
    "u_matSpecular",
    effectiveMaterialColor(
      mat and mat.matSpecular,
      mat and mat.colorsAnimated,
      profileColors and profileColors.specular
    )
  )
  shader:send(
    "u_matEmission",
    effectiveMaterialColor(
      mat and mat.matEmission,
      mat and mat.colorsAnimated,
      profileColors and profileColors.emission
    )
  )
  shader:send("u_texMatrix", "column", mat.texMatrix)

  if mat and mat.image then
    shader:send("u_useTexture", true)
    mesh:setTexture(mat.image)
  else
    shader:send("u_useTexture", false)
    mesh:setTexture()
  end

  shader:send("u_alphaMode", alphaModeId(alphaClass))
  shader:send("u_alphaCutoff", item.alphaCutoff)
  shader:send("u_polygonAlpha", item.polygonAlpha)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  shader:send("u_polygonId", polygonIdOverride or item.polygonId / MapRenderer.REAR_PLANE_ID)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon. A straddling wireframe item takes the
-- same per-vertex bend dispatch as the filled passes: the first `leading`
-- vertices are baked under the straddle transform into a released scratch
-- mesh, exactly like _drawStraddle.
function MapRenderer:_drawWireframe(item, projection, alphaClass)
  if item.straddle then
    self:_drawWireframeStraddle(item, projection, alphaClass)
    return
  end
  self:_drawWireframeMesh(
    item,
    projection,
    item.transform,
    assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    alphaClass
  )
end

-- Draw a straddling wireframe item: bake the shared mesh's vertices under
-- the straddle transform (leading) and the item transform (trailing) into a
-- scratch mesh, draw it with an identity model, and release the scratch
-- within the call -- on the failure path as well as the success path.
function MapRenderer:_drawWireframeStraddle(item, projection, alphaClass)
  local lg = assert(self._graphics)
  local scratch
  local ok, err = pcall(function()
    local vertices = {}
    for i = 1, item.mesh:getVertexCount() do
      vertices[i] = { item.mesh:getVertex(i) }
    end
    scratch = lg.newMesh(
      VertexFormat.LAYOUT,
      MapRenderer.bakeStraddle(vertices, item.straddle.leading, item.straddle.transform, item.transform),
      "triangles",
      "static"
    )
    local map = item.mesh:getVertexMap()
    if map and #map > 0 then
      scratch:setVertexMap(map)
    end
    self:_drawWireframeMesh(item, projection, IDENTITY_MODEL, IDENTITY_MODEL_NORMAL, scratch, alphaClass)
  end)
  if scratch then
    scratch:release()
  end
  if not ok then
    error(err)
  end
end

-- The common wireframe draw body: bind the model/normal matrices, the
-- profile registers, and the rear-plane id, then draw the mesh. The pass owns
-- shader, depth, blend, and wireframe state outside the item loop.
function MapRenderer:_drawWireframeMesh(item, projection, modelMatrix, modelNormal, mesh, alphaClass)
  local lg = assert(self._graphics)
  local shader = self.shader

  shader:send("u_proj", "column", projection)
  shader:send("u_model", "column", modelMatrix)
  shader:send("u_modelNormal", "column", modelNormal)
  -- Wireframe polygons are static field geometry: the effective registers
  -- are the field profile's.
  local profileColors = self._lightMaterialColors
  shader:send("u_matDiffuse", profileColors and profileColors.diffuse or ZERO_COLOR)
  shader:send("u_matAmbient", profileColors and profileColors.ambient or ZERO_COLOR)
  shader:send("u_matSpecular", profileColors and profileColors.specular or ZERO_COLOR)
  shader:send("u_matEmission", profileColors and profileColors.emission or ZERO_COLOR)
  shader:send("u_texMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  shader:send("u_useTexture", false)
  shader:send("u_alphaMode", alphaModeId(alphaClass))
  shader:send("u_alphaCutoff", CUTOUT_EPSILON)
  shader:send("u_polygonAlpha", 1.0)
  shader:send("u_polygonMode", 0)
  -- Wireframe polygons stamp the rear-plane sentinel, normalized by the id
  -- domain exactly like every other id (255/255 == 1.0).
  shader:send("u_polygonId", MapRenderer.REAR_PLANE_ID / MapRenderer.REAR_PLANE_ID)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  mesh:setTexture()
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
end

-- `worldParts` contains ordered arrays of map geometry, building batches, the
-- neighbour ring, and actors. Their traversal position is the queue's
-- deterministic tie-breaker; the renderer draws exactly these parts and no
-- other scene state. `alpha` is the render interpolation
-- factor forwarded to the camera so the scene is viewed from the same smoothed
-- state the actors render at. FieldViewport limits the render-target size and
-- places the result inside the host drawable.
---@param worldParts table[][]?
function MapRenderer:draw(runtime, camera, worldParts, viewport, alpha)
  assert(viewport and viewport.worldViewport, "MapRenderer requires a FieldViewport")
  local lg = assert(self._graphics)
  local parts = worldParts or {}

  self.stats.drawCalls = 0

  local rectangle = viewport.worldViewport
  local w = math.max(1, math.floor(rectangle.width + 0.5))
  local h = math.max(1, math.floor(rectangle.height + 0.5))
  self:_ensureCanvases(w, h)

  local viewMatrix = camera:view(alpha)

  -- Billboard draws own no baked matrix: resolve each one against this frame's
  -- camera before anything reads `transform`, so u_model, the normal matrix,
  -- translucent sorting, and every pass all use the same orientation.
  for _, part in ipairs(parts) do
    for _, d in ipairs(part) do
      if d.billboardBase then
        d.transform, d.modelNormal = BillboardTransform.resolve(d.billboardBase, viewMatrix)
      end
    end
  end

  -- Two projections, computed once per frame: the world projection and the
  -- depth-biased billboard copy (see FieldCamera:billboardProjection). Only
  -- actor billboards opt into the biased matrix; map/building billboards and
  -- static-model actors keep the world projection, as on the DS.
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()

  local sceneTargets = assert(self._sceneTargets)

  local function doDraw()
    lg.setCanvas(sceneTargets)
    lg.clear(BG_COLOR, ID_CLEAR, false, true)
    lg.setShader(self.shader)
    lg.setDepthMode("less", true)
    lg.setBlendMode("alpha")
    self.shader:send("u_view", "column", viewMatrix)

    self:_sendLighting(runtime)
    local queue = RenderQueue.buildInto(parts, viewMatrix, self._queueScratch)

    -- Pass 1: opaque, depth test + write.
    for _, d in ipairs(queue.opaque) do
      local projection = d.billboardProjection and billboardProjection or worldProjection
      self:_drawItem(d, nil, projection, AlphaClassifier.OPAQUE)
    end

    -- Pass 2: cutout, depth test + write, shader discards alpha-zero fragments.
    for _, d in ipairs(queue.cutout) do
      local projection = d.billboardProjection and billboardProjection or worldProjection
      self:_drawItem(d, nil, projection, AlphaClassifier.CUTOUT)
    end

    -- Pass 3: blended, depth test on, write governed by polygon state. The
    -- ID/depth target stays bound so translucent fragments occlude the opaque
    -- geometry behind them for edge marking; they stamp a sentinel ID so the
    -- edge pass never outlines them. The ID/depth attachment carries alpha 1,
    -- so it is replaced -- not alpha-blended -- even while the colour
    -- attachment blends.
    local lastDepthCompare, lastDepthWrite = "less", true
    if #queue.translucent > 0 then
      lg.setBlendMode("alpha", "alphamultiply")
    end
    for _, d in ipairs(queue.translucent) do
      local depthCompare = d.depthEqual and "lequal" or "less"
      local depthWrite = d.translucentDepthWrite or false
      if depthCompare ~= lastDepthCompare or depthWrite ~= lastDepthWrite then
        lg.setDepthMode(depthCompare, depthWrite)
        lastDepthCompare, lastDepthWrite = depthCompare, depthWrite
      end
      local projection = d.billboardProjection and billboardProjection or worldProjection
      self:_drawItem(d, TRANSLUCENT_SENTINEL_ID / MapRenderer.REAR_PLANE_ID, projection, AlphaClassifier.TRANSLUCENT)
    end

    -- Pass 4: wireframe edges (polygon alpha zero). These count as opaque for
    -- edge marking and stamp the rear-plane sentinel into the ID target --
    -- 255/255 == 1.0, the same sentinel the wireframe draw body writes (see
    -- _drawWireframeMesh), never the item's own polygon id.
    lg.setCanvas(sceneTargets)
    if #queue.wireframe > 0 then
      lg.setShader(self.shader)
      lg.setDepthMode("less", true)
      lg.setBlendMode("alpha")
      lg.setWireframe(true)
      for _, d in ipairs(queue.wireframe) do
        local projection = d.billboardProjection and billboardProjection or worldProjection
        self:_drawWireframe(d, projection, AlphaClassifier.WIREFRAME)
      end
      lg.setWireframe(false)
    end

    -- Composite the scene canvas back to the screen through the edge shader,
    -- which outlines polygon-ID boundaries that carry a depth step.
    lg.setCanvas()
    lg.setDepthMode()
    lg.setBlendMode("alpha")
    lg.setColor(1, 1, 1, 1)
    lg.setShader(self.edgeShader)
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
