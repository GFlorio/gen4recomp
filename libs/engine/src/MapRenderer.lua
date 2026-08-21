-- Draws a loaded runtime scene through one world-raster pass and a native
-- presentation sprite stage (see docs/rendering.md). The color raster
-- (sceneColor/colorDepth) and render-state raster (renderState)
-- share bounded world dimensions; actor sprites resolve the world first and
-- draw directly to the host window.
--
-- The world render queue is built exactly once per frame (RenderQueue.buildInto)
-- and the world MRT pass consumes it. Opaque, cutout, and mixed-opaque
-- fragments stamp renderState atomically with color:
-- ID, DS-quantized depth, and per-polygon fog gate. Ordinary translucent and
-- mixed-translucent fragments never touch the state target directly; their
-- state (last translucent ID, fog-gate AND, optional DS Z depth) is
-- maintained by the exact programmable compositor. Approximate mode instead
-- draws the joint `blended` list directly with host alpha blending. The final
-- resolve (edge.glsl) samples sceneColor as its own
-- texture and the same-resolution renderState through explicit snap/clamp to
-- render-state pixel centers (never texture-clamp reliance), probing the four
-- orthogonal neighbors at a distance of one integer edge radius (the rounded
-- field logical pixel scale -- see FieldViewport:logicalPixelScale), and
-- applies, in order: edge marking, fog, then the project's current antialias
-- approximation (50% mix of fogged candidates -- not exact hardware
-- lower-pixel coverage). Both candidates share the center state's single
-- depth/fog state; fog alpha is resolved before the mix.
--
-- A straddling draw item (the first `leading` vertices submitted under a
-- pre-boundary matrix, per the DS geometry engine) is bent per frame, in both
-- passes and the wireframe pass alike: the shared mesh's vertex data is
-- CPU-baked under the two transforms into a scratch mesh drawn with an
-- identity model and released within the frame -- the pool-shared mesh is
-- never mutated. Resource construction is transactional: a failed shader,
-- canvas allocation, or target configuration releases everything already
-- created, and a canvas recreation keeps the previous target set usable until
-- the replacement is complete. It restores the exact caller state it changed
-- (canvas, shader, depth, cull, blend, wireframe, color) even when drawing
-- raises, so the diagnostic UI drawn afterwards is unaffected. It builds no
-- persistent meshes or textures and reads no ROM/NARC data -- those belong to
-- the loader and compiler; here everything is already resident.

local RenderQueue = require("libs.engine.src.RenderQueue")
local BillboardTransform = require("libs.engine.src.BillboardTransform")
local Matrix3 = require("libs.math.src.Matrix3")
local Matrix4 = require("libs.math.src.Matrix4")
local VertexFormat = require("libs.assets.src.VertexFormat")
local FieldLightProfile = require("libs.assets.src.FieldLightProfile")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local FixedPoint = require("libs.math.src.FixedPoint")

---@class MapRenderer
---@field _graphics love.Graphics
---@field clearColor number[]
---@field shader love.Shader
---@field spriteShader love.Shader
---@field _spriteShaderSource string
---@field worldShader love.Shader
---@field edgeShader love.Shader
---@field _edgeColorsCache number[][]
---@field _edgeColorsProfile table<integer, integer>?
---@field _fogColorCache number[]
---@field _fogTableCache number[][]
---@field _fogFinalReference table?
---@field _fogSpriteReference table?
---@field stats { drawCalls: integer, colorDrawCalls: integer, triangles: integer, meshCount: integer, textureCount: integer }
---@field sceneColor love.Canvas?
---@field colorDepth love.Canvas?
---@field renderState love.Canvas?
---@field _spareColor love.Canvas?
---@field _spareState love.Canvas?
---@field _sourceColor love.Canvas?
---@field _sourceMeta love.Canvas?
---@field colorW integer?
---@field colorH integer?
---@field stateW integer?
---@field stateH integer?
---@field _colorTargets { [1]: love.Canvas, [2]: love.Canvas, depthstencil: love.Canvas }?
---@field _stateClearTargets { [1]: love.Canvas, depthstencil: love.Canvas }?
---@field _colorClearTargets { [1]: love.Canvas, depthstencil: love.Canvas }?
---@field _sourceColorTargets { [1]: love.Canvas, depthstencil: love.Canvas }?
---@field _sourceMetaTargets { [1]: love.Canvas, depthstencil: love.Canvas }?
---@field _lightMaterialColorCache { diffuse: number[], ambient: number[], specular: number[], emission: number[] }
---@field _lightVectorCache number[][]
---@field _lightColorCache number[][]
---@field _lightingDelivery table<love.Shader, { lit: boolean, profile: table?, record: table? }>
---@field _queueScratch RenderQueueScratch
---@field _presentationScale number[]
---@field _presentationOffset number[]
---@field worldRasterScale number?
---@field translucencyMode "approximate"|"exact"
local MapRenderer = {}
MapRenderer.__index = MapRenderer

MapRenderer.TRANSLUCENCY_APPROXIMATE = "approximate"
MapRenderer.TRANSLUCENCY_EXACT = "exact"

-- Shader sources are engine assets colocated with this module, addressed by
-- repo-relative path -- the same namespace as every `require`. They are read
-- through the LÖVE resource boundary: love.filesystem resolves the paths from
-- the archive root when the game ships as a .love or fused executable, and
-- in the repo checkout, where the app runs as `love game/` and the engine
-- tree sits outside that source mount, from the host file under the source
-- base directory. `opts.readSource` injects the reader so construction is
-- testable headless without any filesystem.
local SHADER_SOURCE_PATHS = {
  color = "libs/engine/src/shaders/map.glsl",
  resolve = "libs/engine/src/shaders/edge.glsl",
  source = "libs/engine/src/shaders/source.glsl",
  composite = "libs/engine/src/shaders/composite.glsl",
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

-- Fallback scene clear color for callers that do not inject one (e.g. unit
-- tests exercising draw behavior unrelated to background color). Production
-- always injects the game's own color (see MapRenderer.new opts.clearColor);
-- libs/engine must not import game-level config, so this default is the
-- renderer's own and intentionally distinct from any game-chosen value.
local DEFAULT_CLEAR_COLOR = { 0, 0, 0, 1 }
local IDENTITY_MODEL = Matrix4.identity()
local IDENTITY_MODEL_NORMAL = Matrix3.identity()

-- 24-bit rear-plane depth: the maximum value the shader's quantized
-- depth domain can represent.
local DS_DEPTH_MAX = 0xFFFFFF

-- melonDS's RenderFogOffset latch (src/GPU3D.cpp): the raw G3X FOG_OFFSET
-- register is multiplied by this scale once per frame, not per pixel, before
-- reaching the final pass's density calculation (edge.glsl's u_fogOffsetDepth).
local FOG_OFFSET_TO_DEPTH_SCALE = 0x200

-- Rear-plane entry for the renderState target: HGSS's real clear polygon ID
-- (MapRenderer.CLEAR_POLYGON_ID, 63) at the farthest quantized depth
-- (DS_DEPTH_MAX), with its fog gate false -- HGSS's rear plane is not itself
-- fog-gated. Clearing depth to the maximum makes background neighbours read
-- as farther than any real geometry -- that is what outlines silhouettes
-- against the background (GBATEK: at the screen borders edges are resolved
-- against the rear plane's polygon_id). Normalized by the same
-- CLEAR_POLYGON_ID domain maximum every real draw uses (63/63 == 1.0), so a
-- real id-63 polygon is indistinguishable from the background, exactly as
-- GBATEK specifies. This exact table is also edge.glsl's rearPlaneState
-- constant, hand-mirrored there (GLSL has no cross-source include). The alpha
-- channel is the last-translucent-ID encoding: 0 means no accepted translucent
-- overlay yet (the clear/rear plane never has one).
local DS_STATE_CLEAR = { 1, DS_DEPTH_MAX, 0, 0 }

-- Polygon-ID domain (GBATEK POLYGON_ATTR polygon ID, 6-bit 0..63). HGSS
-- initializes the rear/clear plane's polygon ID to 0x3F (63) -- a real,
-- reachable id, not a sentinel outside the domain. Every draw (opaque,
-- cutout, mixed, and wireframe alike) sends its own real polygon ID,
-- normalized by this same domain maximum (id/63; map.glsl and edge.glsl
-- document the encoding/decoding). PolygonState already validates that
-- source polygon ids are integers in 0..63, so this module does not
-- duplicate that validation with its own MAX_POLYGON_ID constant.
MapRenderer.CLEAR_POLYGON_ID = 63

-- Color-pass fragment-pass ids (map.glsl's u_fragmentPass): exact alpha5
-- discard predicates, never a float-epsilon comparison.
local FRAGMENT_PASS_OPAQUE = 0
local FRAGMENT_PASS_CUTOUT = 1
local FRAGMENT_PASS_TRANSLUCENT = 2
local FRAGMENT_PASS_MIXED_OPAQUE = 3
local FRAGMENT_PASS_MIXED_TRANSLUCENT = 4

-- World MRT uses the same fragment-pass ids as the color-only shader.
local function validateWorldRasterScale(scale)
  assert(
    scale == nil
      or (type(scale) == "number" and scale > 0 and scale == scale and scale ~= math.huge and scale ~= -math.huge),
    "world raster scale must be finite and > 0, got " .. tostring(scale)
  )
  return scale
end

---@param displayWidth number
---@param displayHeight number
---@param scale number?
---@return integer, integer
function MapRenderer.worldRasterDimensions(displayWidth, displayHeight, scale)
  assert(displayWidth > 0 and displayHeight > 0)
  validateWorldRasterScale(scale)
  if scale == nil then
    return math.max(1, math.floor(displayWidth + 0.5)), math.max(1, math.floor(displayHeight + 0.5))
  end
  local worldH = math.min(displayHeight, scale * 192)
  local worldW = math.min(displayWidth, math.floor(displayWidth * worldH / displayHeight + 0.5))
  return math.max(1, worldW), math.max(1, math.floor(worldH + 0.5))
end

---@param opts table?
function MapRenderer.new(opts)
  opts = opts or {}
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  assert(graphics, "MapRenderer requires a graphics context")
  local translucencyMode = opts.translucencyMode or MapRenderer.TRANSLUCENCY_APPROXIMATE
  assert(
    translucencyMode == MapRenderer.TRANSLUCENCY_APPROXIMATE or translucencyMode == MapRenderer.TRANSLUCENCY_EXACT,
    "invalid translucency mode: " .. tostring(translucencyMode)
  )
  local worldRasterScale = validateWorldRasterScale(opts.worldRasterScale)
  local readSource = opts.readSource or defaultReadSource
  local renderer = setmetatable({
    _graphics = graphics,
    translucencyMode = translucencyMode,
    worldRasterScale = worldRasterScale,
    clearColor = opts.clearColor or DEFAULT_CLEAR_COLOR,
    _edgeColorsCache = {
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
      { 0, 0, 0 },
    },
    _edgeColorsProfile = nil,
    _fogColorCache = { 0, 0, 0 },
    _fogTableCache = {
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
      { 0, 0, 0, 0 },
    },
    _fogFinalReference = nil,
    _fogSpriteReference = nil,
    stats = { drawCalls = 0, colorDrawCalls = 0, triangles = 0, meshCount = 0, textureCount = 0 },
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
    _lightingDelivery = {},
    _queueScratch = {
      opaque = {},
      cutout = {},
      mixedOpaque = {},
      wireframe = {},
      blended = {},
    },
    _presentationScale = { 1, 1 },
    _presentationOffset = { 0, 0 },
  }, MapRenderer)
  -- Shader construction is transactional: a failure while creating a later
  -- shader (or reading its source) releases every one already created before
  -- the error propagates, so a failed renderer never leaks GPU resources.
  local ok, err = pcall(function()
    local colorSource = readSource(SHADER_SOURCE_PATHS.color)
    renderer.shader = graphics.newShader(colorSource)
    renderer._spriteShaderSource = "#define PRESENTATION_SPRITE\n" .. colorSource
    renderer.edgeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.resolve))
    renderer.worldShader = graphics.newShader("#define WORLD_MRT\n" .. colorSource)
    if translucencyMode == MapRenderer.TRANSLUCENCY_EXACT then
      renderer.sourceShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.source))
      renderer.compositeShader = graphics.newShader(readSource(SHADER_SOURCE_PATHS.composite))
    end
  end)
  if not ok then
    renderer:release()
    error(err)
  end
  return renderer
end

function MapRenderer:_ensureSpriteShader()
  if self.spriteShader then
    return self.spriteShader
  end
  local shader = self._graphics.newShader(self._spriteShaderSource)
  self.spriteShader = shader
  return shader
end

function MapRenderer:_releaseTargets()
  if self.sceneColor then
    self.sceneColor:release()
  end
  if self.colorDepth then
    self.colorDepth:release()
  end
  if self.renderState then
    self.renderState:release()
  end
  if self._spareColor then
    self._spareColor:release()
  end
  if self._spareState then
    self._spareState:release()
  end
  if self._sourceColor then
    self._sourceColor:release()
  end
  if self._sourceMeta then
    self._sourceMeta:release()
  end
  self.sceneColor, self.colorDepth, self.renderState = nil, nil, nil
  self._spareColor, self._spareState = nil, nil
  self._sourceColor, self._sourceMeta = nil, nil
  self.colorW, self.colorH, self.stateW, self.stateH = nil, nil, nil, nil
  self._colorTargets = nil
  self._stateClearTargets = nil
  self._colorClearTargets = nil
  self._sourceColorTargets = nil
  self._sourceMetaTargets = nil
end

local function sendStateUniforms(shader, renderState, stateW, stateH)
  shader:send("u_renderState", renderState)
  shader:send("u_stateSize", { stateW, stateH })
end

-- Recreate every render target at new dimensions. All canvases are allocated
-- and configured into local staged variables before anything published is
-- touched. A failure releases only that incomplete generation and leaves the
-- previous target set and its recorded dimensions untouched.
function MapRenderer:_ensureTargets(colorW, colorH)
  if
    self.sceneColor
    and self.colorW == colorW
    and self.colorH == colorH
    and self.stateW == colorW
    and self.stateH == colorH
  then
    return
  end
  local lg = assert(self._graphics)
  local sceneColor, colorDepth, renderState
  local spareColor, spareState, sourceColor, sourceMeta
  local colorTargets, stateClearTargets, colorClearTargets
  local sourceColorTargets, sourceMetaTargets
  local ok, err = pcall(function()
    sceneColor = lg.newCanvas(colorW, colorH)
    -- Nearest sampling keeps the final composite draw (a 1:1 blit at
    -- presentation resolution) from introducing interpolation of its own.
    sceneColor:setFilter("nearest", "nearest")
    colorDepth = lg.newCanvas(colorW, colorH, { format = "depth24stencil8", readable = false })

    -- renderState: red the normalized opaque edge polygon ID, green the
    -- DS Z-buffer depth (a 24-bit integer domain, stored as a
    -- float -- see dsZbufferDepth in map.glsl), blue the per-polygon fog
    -- gate, alpha the last-translucent-ID encoding (0 = none, (id+1)/64).
    -- The state canvas shares the color canvas's exact dimensions: state
    -- classification is never deliberately downsampled, and the final resolve
    -- probes this same-resolution state at a sampling distance of one integer
    -- edge radius. The format must be 32-bit float: the quantized depth spans
    -- the full 24-bit domain, which 16-bit floats cannot resolve exactly.
    renderState = lg.newCanvas(colorW, colorH, { format = "rgba32f" })
    renderState:setFilter("nearest", "nearest")
    colorTargets = { sceneColor, renderState, depthstencil = colorDepth }
    stateClearTargets = { renderState, depthstencil = colorDepth }
    colorClearTargets = { sceneColor, depthstencil = colorDepth }

    if self.translucencyMode == MapRenderer.TRANSLUCENCY_EXACT then
      -- Exact mode alternates one spare destination pair with the active pair.
      spareColor = lg.newCanvas(colorW, colorH)
      spareColor:setFilter("nearest", "nearest")
      spareState = lg.newCanvas(colorW, colorH, { format = "rgba32f" })
      spareState:setFilter("nearest", "nearest")

      -- Exact source metadata uses rgba8. The ID encoding in source.glsl is
      -- (id + 1) / 64, so every 6-bit ID survives normalized storage.
      sourceColor = lg.newCanvas(colorW, colorH)
      sourceColor:setFilter("nearest", "nearest")
      sourceMeta = lg.newCanvas(colorW, colorH, { format = "rgba8" })
      sourceMeta:setFilter("nearest", "nearest")
      sourceColorTargets = { sourceColor, depthstencil = colorDepth }
      sourceMetaTargets = { sourceMeta, depthstencil = colorDepth }
    end
  end)
  if not ok then
    for _, canvas in ipairs({
      sceneColor,
      colorDepth,
      renderState,
      spareColor,
      spareState,
      sourceColor,
      sourceMeta,
    }) do
      if canvas then
        pcall(canvas.release, canvas)
      end
    end
    error(err)
  end
  self:_releaseTargets()
  self.sceneColor, self.colorDepth, self.renderState = sceneColor, colorDepth, renderState
  self._spareColor, self._spareState = spareColor, spareState
  self._sourceColor, self._sourceMeta = sourceColor, sourceMeta
  self.colorW, self.colorH, self.stateW, self.stateH = colorW, colorH, colorW, colorH
  self._colorTargets = colorTargets
  self._stateClearTargets = stateClearTargets
  self._colorClearTargets = colorClearTargets
  self._sourceColorTargets = sourceColorTargets
  self._sourceMetaTargets = sourceMetaTargets
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

-- 5-bit (0-31) RGB555 component -> the DS six-bit framebuffer domain
-- (melonDS GPU3D_Soft.cpp color conversion): 0 stays 0, any non-zero n
-- becomes 2n+1, normalized by 63. Used only for edge colors, which composite
-- directly into the six-bit scene RGB; material/light registers stay 5-bit
-- and must keep using decodeRgb555 above.
local function expand5to6(c5)
  if c5 <= 0 then
    return 0
  end
  return c5 * 2 + 1
end

local function decodeRgb555ToRgb6Normalized(target, packed)
  target[1] = expand5to6(packed % 32) / 63
  target[2] = expand5to6(math.floor(packed / 32) % 32) / 63
  target[3] = expand5to6(math.floor(packed / 1024) % 32) / 63
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
function MapRenderer:_sendLighting(sceneRuntime, targetShader)
  assert(targetShader, "lighting delivery requires an explicit shader")
  assert(
    targetShader == self.shader or targetShader == self.worldShader or targetShader == self.spriteShader,
    "lighting target is not owned by this renderer"
  )
  local shader = targetShader
  local profile = sceneRuntime.lighting
  if not profile or not profile.records then
    local delivery = self._lightingDelivery[shader]
    if delivery and not delivery.lit and delivery.profile == nil and delivery.record == nil then
      self._lightMaterialColors = nil
      return
    end
    for i = 0, 3 do
      shader:send("u_lightEnabled" .. i, false)
      shader:send("u_lightVector" .. i, ZERO_COLOR)
      shader:send("u_lightColor" .. i, ZERO_COLOR)
    end
    self._lightingDelivery[shader] = { lit = false, profile = nil, record = nil }
    self._lightMaterialColors = nil
    return
  end

  local record =
    FieldLightProfile.select(profile, sceneRuntime.fieldTimeSeconds or FieldLightProfile.DEFAULT_TIME_SECONDS)
  local delivery = self._lightingDelivery[shader]
  if delivery and delivery.lit and delivery.profile == profile and delivery.record == record then
    self._lightMaterialColors = self._lightMaterialColorCache
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
  self._lightingDelivery[shader] = { lit = true, profile = profile, record = record }
  self._lightMaterialColors = materialColors
end

-- Edge colors are scene state, never a constructor invariant: the
-- compiled area's real HGSS eight-entry RGB555 table (HgssFieldEdgeColors),
-- decoded into the persistent cache and resent only when the scene supplies a
-- different table reference -- the same reference-equality cache pattern as
-- _sendLighting's profile/record tracking. Every compiled HGSS field scene
-- carries this table unconditionally (edge marking is always enabled), so a
-- missing table is a collaborator gone missing, not a case to default around.
function MapRenderer:_sendEdgeColors(sceneRuntime)
  local edgeColors = assert(sceneRuntime.edgeColors, "scene runtime requires an edgeColors table")
  if self._edgeColorsProfile == edgeColors then
    return
  end
  local decoded = self._edgeColorsCache
  for i = 0, 7 do
    decodeRgb555ToRgb6Normalized(decoded[i + 1], edgeColors[i])
  end
  self.edgeShader:send("u_edgeColors", unpack(decoded))
  self._edgeColorsProfile = edgeColors
end

-- The scene's resolved global HGSS weather fog preset is delivered to each
-- consumer only when that consumer's reference changes. Each reference is
-- advanced only after that consumer accepts the complete payload.
local function sendFogPayload(renderer, shader, fog)
  decodeRgb555(renderer._fogColorCache, fog.color)
  local groups = renderer._fogTableCache
  for group = 0, 7 do
    local values = groups[group + 1]
    local first = group * 4 + 1
    values[1], values[2], values[3], values[4] =
      fog.table[first], fog.table[first + 1], fog.table[first + 2], fog.table[first + 3]
  end

  local fogOffsetDepth = fog.offset * FOG_OFFSET_TO_DEPTH_SCALE
  shader:send("u_fogEnabled", fog.enabled)
  shader:send("u_fogColor", renderer._fogColorCache)
  -- The 32-entry density table is delivered as 8 groups of 4 raw entries,
  -- one named uniform each: LÖVE 11.5 fills only the first vec4 of a
  -- `vec4[N]` array uniform from a flat table, so a single-array send could
  -- never reach entries past index 0 (see edge.glsl's fogTableEntry). fog.table
  -- is the 1-indexed 32-entry preset table; group i covers entries
  -- 4*i+1 .. 4*i+4.
  for group = 0, 7 do
    shader:send("u_fogTable" .. group, groups[group + 1])
  end
  shader:send("u_fogOffsetDepth", fogOffsetDepth)
  shader:send("u_fogShift", fog.slope)
  shader:send("u_fogAlpha", fog.alpha)
end

function MapRenderer:_sendFog(sceneRuntime)
  local fog = assert(sceneRuntime.fog, "scene runtime requires a fog preset")
  if self._fogFinalReference == fog then
    return
  end
  sendFogPayload(self, self.edgeShader, fog)
  self._fogFinalReference = fog
end

-- Presentation sprites use the same fog payload and DS depth conversion as
-- the resolved world, but evaluate fog from their own host fragment depth.
function MapRenderer:_sendSpriteFog(sceneRuntime)
  local fog = assert(sceneRuntime.fog, "scene runtime requires a fog preset")
  local shader = self._activeShader or self.shader
  if self._fogSpriteReference == fog then
    return
  end
  local ok, err = pcall(sendFogPayload, self, shader, fog)
  if not ok then
    error(err, 0)
  end
  self._fogSpriteReference = fog
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

-- Bind the model/normal matrices or billboard placement common to both the
-- filled and wireframe draw bodies (_drawMesh, _drawWireframeMesh).
local function sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)
  shader:send("u_proj", "column", projection)
  local isBillboard = billboardCenter ~= nil
  shader:send("u_billboard", isBillboard)
  if isBillboard then
    assert(billboardScale, "billboard draw requires billboardScale")
    shader:send("u_billboardCenter", billboardCenter)
    shader:send("u_billboardScale", billboardScale)
  else
    shader:send("u_model", "column", modelMatrix)
    shader:send("u_modelNormal", "column", modelNormal)
  end
end

-- Bind placement for metadata shaders that do not perform vertex lighting.
local function sendPlacementUniforms(shader, projection, modelMatrix, billboardCenter, billboardScale)
  shader:send("u_proj", "column", projection)
  local isBillboard = billboardCenter ~= nil
  shader:send("u_billboard", isBillboard)
  if isBillboard then
    assert(billboardScale, "billboard draw requires billboardScale")
    shader:send("u_billboardCenter", billboardCenter)
    shader:send("u_billboardScale", billboardScale)
  else
    shader:send("u_model", "column", modelMatrix)
  end
end

-- Bake a straddling item's shared mesh into a scratch mesh under the item's
-- two submission transforms (see MapRenderer.bakeStraddle), resolving a
-- billboard base through the current view first if the item is a
-- billboarded straddle. Shared by every straddle draw path (color, state,
-- and wireframe): all bake identically and differ only in which draw body
-- consumes the result. The caller owns releasing the returned mesh.
local function bakeStraddleMesh(lg, item, viewMatrix)
  -- love 11.5 has no Mesh:getVertices bulk read; the CPU-side vertex data is
  -- still reachable per vertex (getVertex returns the attribute components
  -- as multiple values on this build).
  local vertices = {}
  for i = 1, item.mesh:getVertexCount() do
    vertices[i] = { item.mesh:getVertex(i) }
  end
  local transform = item.transform
  if item.billboardBase then
    -- A billboarded straddle still has mixed submission transforms, so keep
    -- the proven CPU bend until that exceptional combination has an exact
    -- view-space equivalent.
    transform =
      BillboardTransform.resolve(item.billboardBase, assert(viewMatrix, "straddle billboard needs a view matrix"))
  end
  local scratch = lg.newMesh(
    VertexFormat.LAYOUT,
    MapRenderer.bakeStraddle(vertices, item.straddle.leading, item.straddle.transform, transform),
    "triangles",
    "static"
  )
  local map = item.mesh:getVertexMap()
  if map and #map > 0 then
    scratch:setVertexMap(map)
  end
  return scratch
end

-- Bind a material's uniforms/texture/cull state, then draw the mesh.
-- `projection` is per item: billboard actors draw through the camera's
-- field-billboard projection, everything else through the world projection.
-- `modelMatrix`/`modelNormal` are the item's unless the item straddles (a
-- straddling item draws its baked world-space scratch mesh with an identity
-- model). `fragmentPass` was selected by the caller and is sent as-is.
function MapRenderer:_drawItem(item, projection, fragmentPass, viewMatrix)
  if item.straddle then
    self:_drawStraddle(item, projection, fragmentPass, viewMatrix)
    return
  end
  self:_drawMesh(
    item,
    projection,
    item.transform,
    item.billboardCenter and IDENTITY_MODEL_NORMAL or assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    fragmentPass,
    item.billboardCenter,
    item.billboardScale
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
function MapRenderer:_drawStraddle(item, projection, fragmentPass, viewMatrix)
  local lg = assert(self._graphics)
  local scratch
  local ok, err = pcall(function()
    scratch = bakeStraddleMesh(lg, item, viewMatrix)
    self:_drawMesh(item, projection, IDENTITY_MODEL, IDENTITY_MODEL_NORMAL, scratch, fragmentPass, nil, nil)
  end)
  if scratch then
    scratch:release()
  end
  if not ok then
    error(err)
  end
end

-- The common draw body: bind the model/normal matrices or billboard placement,
-- the material's
-- uniforms/texture/cull state, draw the mesh, and count the call.
function MapRenderer:_drawMesh(
  item,
  projection,
  modelMatrix,
  modelNormal,
  mesh,
  fragmentPass,
  billboardCenter,
  billboardScale
)
  local lg = assert(self._graphics)
  local mat = item.material
  local shader = self._activeShader or self.shader

  sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)

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

  shader:send("u_fragmentPass", fragmentPass)
  shader:send("u_polygonAlpha", item.polygonAlpha)
  shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  if shader == self.worldShader then
    shader:send("u_polygonId", item.polygonId / MapRenderer.CLEAR_POLYGON_ID)
    shader:send("u_polygonFogEnabled", item.fogEnabled == true)
  end
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 1
end

-- Draw the edges of a wireframe batch through the same projection path as
-- filled geometry. The DS draws polygon alpha zero as wireframe edges rather
-- than an invisible filled polygon. A straddling wireframe item takes the
-- same per-vertex bend dispatch as the filled passes: the first `leading`
-- vertices are baked under the straddle transform into a released scratch
-- mesh, exactly like _drawStraddle.
function MapRenderer:_drawWireframe(item, projection, viewMatrix)
  if item.straddle then
    self:_drawWireframeStraddle(item, projection, viewMatrix)
    return
  end
  self:_drawWireframeMesh(
    item,
    projection,
    item.transform,
    item.billboardCenter and IDENTITY_MODEL_NORMAL or assert(item.modelNormal, "render item requires modelNormal"),
    item.mesh,
    item.billboardCenter,
    item.billboardScale
  )
end

-- Draw a straddling wireframe item: bake the shared mesh's vertices under
-- the straddle transform (leading) and the item transform (trailing) into a
-- scratch mesh, draw it with an identity model, and release the scratch
-- within the call -- on the failure path as well as the success path.
function MapRenderer:_drawWireframeStraddle(item, projection, viewMatrix)
  local lg = assert(self._graphics)
  local scratch
  local ok, err = pcall(function()
    scratch = bakeStraddleMesh(lg, item, viewMatrix)
    self:_drawWireframeMesh(item, projection, IDENTITY_MODEL, IDENTITY_MODEL_NORMAL, scratch, nil, nil)
  end)
  if scratch then
    scratch:release()
  end
  if not ok then
    error(err)
  end
end

-- The common wireframe draw body: bind the model/normal matrices, the
-- profile registers, and draw the mesh. The pass owns shader, depth, blend,
-- and wireframe state outside the item loop. Wireframe items always draw as
-- opaque (GBATEK: edge marking applies to wire-frames too).
function MapRenderer:_drawWireframeMesh(
  item,
  projection,
  modelMatrix,
  modelNormal,
  mesh,
  billboardCenter,
  billboardScale
)
  local lg = assert(self._graphics)
  local shader = self._activeShader or self.shader

  sendTransformUniforms(shader, projection, modelMatrix, modelNormal, billboardCenter, billboardScale)
  -- Wireframe polygons are static field geometry: the effective registers
  -- are the field profile's.
  local profileColors = self._lightMaterialColors
  shader:send("u_matDiffuse", profileColors and profileColors.diffuse or ZERO_COLOR)
  shader:send("u_matAmbient", profileColors and profileColors.ambient or ZERO_COLOR)
  shader:send("u_matSpecular", profileColors and profileColors.specular or ZERO_COLOR)
  shader:send("u_matEmission", profileColors and profileColors.emission or ZERO_COLOR)
  shader:send("u_texMatrix", "column", { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  shader:send("u_useTexture", false)
  shader:send("u_fragmentPass", FRAGMENT_PASS_OPAQUE)
  shader:send("u_polygonAlpha", 1.0)
  shader:send("u_polygonMode", 0)
  shader:send("u_lightMask", LIGHT_MASK_UNIFORMS[item.lightMask])
  if shader == self.worldShader then
    shader:send("u_polygonId", item.polygonId / MapRenderer.CLEAR_POLYGON_ID)
    shader:send("u_polygonFogEnabled", item.fogEnabled == true)
  end
  mesh:setTexture()
  lg.setMeshCullMode(item.cullMode)
  lg.draw(mesh)
  self.stats.drawCalls = self.stats.drawCalls + 1
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 1
end

-- Rasterize ONE blended item's partial-alpha fragments into the temporary
-- source buffers for the compositor. Two passes over the same geometry:
--   1. the ordinary color shader (map.glsl) with the translucent fragment
--      pass renders the item's partial-alpha fragments into sourceColor --
--      the exact combiner/lighting color, no duplication;
--   2. source.glsl renders the same fragments into sourceMeta -- the
--      valid/fog/id metadata -- applying the DS same-ID rejection against the
--      ACTIVE destination state. Both passes depth-test against the current
--      opaque host depth attachment and use replace semantics without writing
--      it.
function MapRenderer:_drawSourceItem(item, projection, fragmentPass, viewMatrix, activeState, stateW, stateH)
  local lg = assert(self._graphics)
  local mat = item.material

  -- Pass 1: source color through the ordinary color shader (the same
  -- _drawItem dispatch the color pass uses, so straddle bending, lighting,
  -- materials, and billboard projection are all identical).
  lg.setCanvas(assert(self._sourceColorTargets))
  lg.setShader(self.shader)
  lg.setDepthMode("less", false)
  lg.setBlendMode("replace", "premultiplied")
  self.shader:send("u_view", "column", viewMatrix)
  self:_drawItem(item, projection, fragmentPass, viewMatrix)

  -- Pass 2: source metadata through source.glsl (same-ID rejection + fog flag
  -- + id).
  lg.setCanvas(assert(self._sourceMetaTargets))
  lg.clear(0, 0, 0, 0, false, false)
  lg.setShader(self.sourceShader)
  lg.setDepthMode("less", false)
  lg.setBlendMode("replace", "premultiplied")
  self.sourceShader:send("u_view", "column", viewMatrix)

  if item.straddle then
    self:_drawSourceStraddleMeta(item, projection, fragmentPass, viewMatrix, activeState, stateW, stateH)
  else
    sendPlacementUniforms(self.sourceShader, projection, item.transform, item.billboardCenter, item.billboardScale)
    self.sourceShader:send("u_texMatrix", "column", mat.texMatrix)
    if mat and mat.image then
      self.sourceShader:send("u_useTexture", true)
      item.mesh:setTexture(mat.image)
    else
      self.sourceShader:send("u_useTexture", false)
      item.mesh:setTexture()
    end
    self.sourceShader:send("u_fragmentPass", fragmentPass)
    self.sourceShader:send("u_polygonAlpha", item.polygonAlpha)
    self.sourceShader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
    self.sourceShader:send("u_polygonId", item.polygonId / MapRenderer.CLEAR_POLYGON_ID)
    self.sourceShader:send("u_polygonFogEnabled", item.fogEnabled == true)
    self.sourceShader:send("u_activeState", activeState)
    self.sourceShader:send("u_stateSize", { stateW, stateH })
    lg.setMeshCullMode(item.cullMode)
    lg.draw(item.mesh)
  end
  self.stats.drawCalls = self.stats.drawCalls + 2
  self.stats.colorDrawCalls = self.stats.colorDrawCalls + 2
end

-- A straddling blended item through the source metadata pass: the first
-- `leading` vertices are baked under the straddle transform into a scratch
-- mesh and the rest under the item transform, exactly like the color pass's
-- straddle path (the source pass shares the same per-vertex bend dispatch).
function MapRenderer:_drawSourceStraddleMeta(item, projection, fragmentPass, viewMatrix, activeState, stateW, stateH)
  local lg = assert(self._graphics)
  local scratch
  local ok, err = pcall(function()
    scratch = bakeStraddleMesh(lg, item, viewMatrix)
    local shader = self.sourceShader
    sendPlacementUniforms(shader, projection, IDENTITY_MODEL, nil, nil)
    shader:send("u_texMatrix", "column", item.material.texMatrix)
    if item.material and item.material.image then
      shader:send("u_useTexture", true)
      scratch:setTexture(item.material.image)
    else
      shader:send("u_useTexture", false)
      scratch:setTexture()
    end
    shader:send("u_fragmentPass", fragmentPass)
    shader:send("u_polygonAlpha", item.polygonAlpha)
    shader:send("u_polygonMode", item.polygonMode == "decal" and 1 or 0)
    shader:send("u_polygonId", item.polygonId / MapRenderer.CLEAR_POLYGON_ID)
    shader:send("u_polygonFogEnabled", item.fogEnabled == true)
    shader:send("u_activeState", activeState)
    shader:send("u_stateSize", { stateW, stateH })
    lg.setMeshCullMode(item.cullMode)
    lg.draw(scratch)
  end)
  if scratch then
    scratch:release()
  end
  if not ok then
    error(err)
  end
end

-- `worldParts` contains ordered arrays of map geometry, building batches, the
-- neighbour ring, and actors. Their traversal position is the queue's
-- deterministic tie-breaker; the renderer draws exactly these parts and no
-- other scene state. `alpha` is the render interpolation
-- factor forwarded to the camera so the scene is viewed from the same smoothed
-- state the actors render at. FieldViewport limits the render-target size and
-- places the result inside the host drawable.
---@param worldParts table[][]?
---@param spriteItems table[]?
---@param viewport { worldViewport: { x: number, y: number, width: number, height: number } }
---@param alpha number
function MapRenderer:draw(sceneRuntime, camera, worldParts, spriteItems, viewport, alpha)
  assert(viewport and viewport.worldViewport, "MapRenderer requires a FieldViewport")
  -- The world MRT shader derives its depth from the host fragment's normalized
  -- window depth (map.glsl's dsZbufferDepth, the HGSS field Z-buffer
  -- domain) -- no camera far plane is sent for depth normalization. The
  -- camera's far plane still participates in the frame through its own
  -- projection matrices (camera:projection()/camera:billboardProjection()),
  -- so a camera without one is a malformed collaborator, not a case to
  -- default around.
  assert(type(camera.far) == "number" and camera.far > 0, "MapRenderer requires camera.far to be a positive number")
  local lg = assert(self._graphics)
  local parts = worldParts or {}

  self.stats.drawCalls = 0
  self.stats.colorDrawCalls = 0

  local rectangle = viewport.worldViewport
  local colorW, colorH = MapRenderer.worldRasterDimensions(rectangle.width, rectangle.height, self.worldRasterScale)
  self:_ensureTargets(colorW, colorH)

  local viewMatrix = camera:view(alpha)

  -- Two projections, computed once per frame: the world projection and the
  -- depth-biased billboard copy (see FieldCamera:billboardProjection). Only
  -- actor billboards opt into the biased matrix; map/building billboards and
  -- static-model actors keep the world projection, as on the DS. Both the
  -- state and color passes select projection identically per item.
  local worldProjection = camera:projection()
  local billboardProjection = camera:billboardProjection()
  local function projectionFor(item)
    return item.billboardProjection and billboardProjection or worldProjection
  end

  local colorTargets = assert(self._colorTargets)

  -- The final pass samples neighbors in world-raster pixels, so edge width
  -- remains tied to the DS-relative world rather than host resolution.
  local edgeRadiusPx = 1
  local cameraZoom = camera.zoom
  if cameraZoom == nil then
    cameraZoom = 1
  end
  if type(cameraZoom) == "number" and cameraZoom > 0 then
    edgeRadiusPx = math.max(1, math.floor((colorH / 192) * cameraZoom + 0.5))
  end

  local presentationCanvas = lg.getCanvas()
  local function doDraw()
    local presentationColorCanvas = presentationCanvas
    ---@diagnostic disable-next-line: undefined-field
    if
      type(presentationCanvas) == "table"
      and (presentationCanvas[1] ~= nil or rawget(presentationCanvas, "color") ~= nil)
    then
      ---@diagnostic disable-next-line: undefined-field
      presentationColorCanvas = presentationCanvas[1] or rawget(presentationCanvas, "color")
      if type(presentationColorCanvas) == "table" then
        presentationColorCanvas = presentationColorCanvas[1] or presentationColorCanvas.canvas
      end
      assert(presentationColorCanvas, "MapRenderer requires a color presentation target")
    end

    -- The render queue is built exactly once per frame.
    local queue = RenderQueue.buildInto(parts, viewMatrix, self._queueScratch)

    -- ---- world MRT pass: color and polygon state ----
    lg.setCanvas(assert(self._stateClearTargets))
    lg.clear(DS_STATE_CLEAR, false, true)
    lg.setCanvas(assert(self._colorClearTargets))
    lg.clear(self.clearColor, false, false)
    lg.setCanvas(colorTargets)
    lg.setShader(self.worldShader)
    lg.setDepthMode("less", true)
    lg.setBlendMode("replace", "premultiplied")
    self._activeShader = self.worldShader
    self.worldShader:send("u_view", "column", viewMatrix)
    self:_sendLighting(sceneRuntime, self.worldShader)

    for _, d in ipairs(queue.opaque) do
      self:_drawItem(d, projectionFor(d), FRAGMENT_PASS_OPAQUE, viewMatrix)
    end
    for _, d in ipairs(queue.cutout) do
      self:_drawItem(d, projectionFor(d), FRAGMENT_PASS_CUTOUT, viewMatrix)
    end
    for _, d in ipairs(queue.mixedOpaque) do
      self:_drawItem(d, projectionFor(d), FRAGMENT_PASS_MIXED_OPAQUE, viewMatrix)
    end
    self._activeShader = nil

    -- ---- translucent compositor ----
    -- The DS translucent path needs per-pixel state that fixed-function host
    -- blending cannot express: same-ID rejection against the pixel's last
    -- translucent ID, max destination alpha, fog-gate AND, and
    -- last-translucent-ID state mutation. The pipeline is a ping-pong
    -- read-modify-write: each blended item's partial-alpha fragments are
    -- rasterized into temporary source buffers (depth-tested against the
    -- current host depth, same-ID-rejected against the active destination
    -- state), then a full-screen composite applies the exact integer DS
    -- blend/state equations into the INACTIVE destination pair, then the
    -- pairs swap. No pass samples and writes the same target.
    --
    -- The active destination starts as the opaque color/state canvases
    -- (sceneColor/renderState); after every blended item the composite output
    -- is the new active pair, so wireframe and the final resolve below see the
    -- fully composited color and state.
    local activeColor, activeState = self.sceneColor, self.renderState
    if self.translucencyMode == MapRenderer.TRANSLUCENCY_APPROXIMATE then
      if #queue.blended > 0 then
        self:_sendLighting(sceneRuntime, self.shader)
        ---@type { [1]: love.Canvas, depthstencil: love.Canvas }
        local approximateTargets = { assert(self.sceneColor), depthstencil = assert(self.colorDepth) }
        lg.setCanvas(approximateTargets)
        lg.setShader(self.shader)
        lg.setDepthMode("less", false)
        lg.setBlendMode("alpha", "alphamultiply")
        self.shader:send("u_view", "column", viewMatrix)
        for _, entry in ipairs(queue.blended) do
          local fragmentPass = entry.fragmentPass == AlphaClassifier.MIXED and FRAGMENT_PASS_MIXED_TRANSLUCENT
            or FRAGMENT_PASS_TRANSLUCENT
          self:_drawItem(entry.item, projectionFor(entry.item), fragmentPass, viewMatrix)
        end
      end
    elseif #queue.blended > 0 then
      self:_sendLighting(sceneRuntime, self.shader)
      local inactiveColor, inactiveState = assert(self._spareColor), assert(self._spareState)
      local function swap()
        activeColor, activeState, inactiveColor, inactiveState = inactiveColor, inactiveState, activeColor, activeState
      end
      self.compositeShader:send("u_sourceColor", self._sourceColor)
      self.compositeShader:send("u_sourceMeta", self._sourceMeta)
      self.compositeShader:send("u_size", { colorW, colorH })
      for _, entry in ipairs(queue.blended) do
        local d = entry.item
        -- Depth-equal is a corpus-provable-absent DS state (see
        -- PolygonState.validate's POLYGON_STATE_DEPTH_EQUAL_UNSUPPORTED
        -- rejection): the renderer never branches on d.depthEqual and always
        -- compares "less", even if a defensively-constructed item still
        -- carries the field. Host `lequal` is retired, not merely unused.
        local fragmentPass = entry.fragmentPass == AlphaClassifier.MIXED and FRAGMENT_PASS_MIXED_TRANSLUCENT
          or FRAGMENT_PASS_TRANSLUCENT
        self:_drawSourceItem(d, projectionFor(d), fragmentPass, viewMatrix, activeState, colorW, colorH)

        -- Full-screen composite from the source buffers + active pair into
        -- the inactive pair, with replace semantics (no second host blend).
        lg.setCanvas(inactiveColor, inactiveState)
        lg.setDepthMode()
        lg.setBlendMode("replace", "premultiplied")
        lg.setColor(1, 1, 1, 1)
        lg.setShader(self.compositeShader)
        self.compositeShader:send("u_activeColor", activeColor)
        self.compositeShader:send("u_activeState", activeState)
        lg.draw(self._sourceColor, 0, 0)
        lg.setShader()
        swap()
      end
      -- Publish the composited pair as the renderer's public sceneColor/
      -- renderState fields and make the former active pair the spare. The
      -- next frame's composite reads the active pair and copies invalid
      -- source pixels directly from it.
      self.sceneColor, self.renderState = activeColor, activeState
      local publishedTargets = assert(self._colorTargets)
      publishedTargets[1], publishedTargets[2] = activeColor, activeState
      assert(self._stateClearTargets)[1] = activeState
      assert(self._colorClearTargets)[1] = activeColor
      self._spareColor, self._spareState = inactiveColor, inactiveState
    end

    -- Wireframe edges (polygon alpha zero): these count as opaque for edge
    -- marking; the color pass draws them for their own visible RGB. They
    -- target the ACTIVE color/state pair so the final resolve sees them
    -- composited with any translucent overlays.
    if #queue.wireframe > 0 then
      lg.setCanvas(assert(self._colorTargets))
      lg.setShader(self.worldShader)
      self._activeShader = self.worldShader
      lg.setDepthMode("less", true)
      lg.setBlendMode("replace", "premultiplied")
      lg.setWireframe(true)
      for _, d in ipairs(queue.wireframe) do
        self:_drawWireframe(d, projectionFor(d), viewMatrix)
      end
      self._activeShader = nil
      lg.setWireframe(false)
    end

    -- ---- final resolve: edge marking, fog, then the current AA approximation ----
    self:_sendEdgeColors(sceneRuntime)
    self:_sendFog(sceneRuntime)
    self.edgeShader:send("u_antialiasEnabled", true)
    self.edgeShader:send("u_edgeRadiusPx", edgeRadiusPx)
    lg.setCanvas(presentationCanvas)
    lg.setDepthMode()
    lg.setBlendMode("replace", "premultiplied")
    lg.setColor(1, 1, 1, 1)
    lg.setShader(self.edgeShader)
    sendStateUniforms(self.edgeShader, activeState, self.stateW, self.stateH)
    lg.draw(activeColor, rectangle.x, rectangle.y, 0, rectangle.width / colorW, rectangle.height / colorH)
    lg.setShader()

    -- The world is now present at presentation resolution. The host depth
    -- buffer is borrowed for actor ordering; it is cleared without changing
    -- the resolved world color, then the presentation sprites draw directly
    -- to the window. No sprite color or state canvas is allocated.
    if spriteItems and #spriteItems > 0 then
      lg.clear(nil, nil, nil, nil, false, true)
      self._activeShader = self:_ensureSpriteShader()
      local spriteShader = assert(self._activeShader)
      spriteShader:send("u_presentationSprite", true)
      local targetWidth, targetHeight
      if presentationCanvas then
        ---@type love.Canvas & { getWidth: fun(self: love.Canvas): integer, getHeight: fun(self: love.Canvas): integer }
        local colorCanvas = assert(presentationColorCanvas)
        ---@diagnostic disable-next-line: undefined-field
        targetWidth, targetHeight = colorCanvas:getWidth(), colorCanvas:getHeight()
      else
        targetWidth, targetHeight = lg.getDimensions()
      end
      assert(targetWidth > 0 and targetHeight > 0, "MapRenderer requires positive presentation target dimensions")
      local scale = self._presentationScale
      local offset = self._presentationOffset
      scale[1] = rectangle.width / targetWidth
      scale[2] = rectangle.height / targetHeight
      offset[1] = (2 * rectangle.x + rectangle.width) / targetWidth - 1
      offset[2] = 1 - (2 * rectangle.y + rectangle.height) / targetHeight
      if presentationCanvas then
        scale[2] = -scale[2]
        offset[2] = -offset[2]
      end
      spriteShader:send("u_presentationScale", scale)
      spriteShader:send("u_presentationOffset", offset)
      spriteShader:send("u_view", "column", viewMatrix)
      spriteShader:send("u_renderState", activeState)
      spriteShader:send("u_stateSize", { self.stateW, self.stateH })
      self:_sendSpriteFog(sceneRuntime)
      self:_sendLighting(sceneRuntime, spriteShader)
      lg.setShader(spriteShader)
      lg.setBlendMode("replace", "premultiplied")

      local function drawSprite(item, fragmentPass)
        spriteShader:send("u_spriteFogEnabled", item.fogEnabled == true)
        lg.setDepthMode("less", true)
        self:_drawItem(item, billboardProjection, fragmentPass, viewMatrix)
      end
      for _, item in ipairs(spriteItems) do
        local fragmentPass
        if item.alphaClass == AlphaClassifier.OPAQUE then
          fragmentPass = FRAGMENT_PASS_OPAQUE
        elseif item.alphaClass == AlphaClassifier.CUTOUT then
          fragmentPass = FRAGMENT_PASS_CUTOUT
        else
          error("ordinary billboard has unsupported alpha class: " .. tostring(item.alphaClass))
        end
        drawSprite(item, fragmentPass)
      end
      self._activeShader = nil
    end
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

  self._activeShader = nil
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
  if self.worldShader then
    self.worldShader:release()
  end
  if self.sourceShader then
    self.sourceShader:release()
  end
  if self.compositeShader then
    self.compositeShader:release()
  end
  if self.spriteShader then
    self.spriteShader:release()
  end
  self.shader, self.worldShader, self.spriteShader, self.edgeShader = nil, nil, nil, nil
  self.sourceShader, self.compositeShader = nil, nil
  self:_releaseTargets()
end

return MapRenderer
