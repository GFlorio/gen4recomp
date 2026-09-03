-- Graphics regression for terrain T-seams through the real world-MRT path.
--
-- Two opaque adjacent batches share the NDC span x=0, y in [-0.8,0.8]: the
-- left batch breaks the span at P=(0,0.25,0) while the right batch spans it
-- unbroken. Both render through GxRenderer's world MRT across a subpixel
-- sweep at world-raster scales 1 and 3, and the renderState target is
-- scanned for isolated enclosed rear-plane samples (a rear-plane pixel whose
-- eight neighbors all drew terrain). The unconformed control proves the
-- fixture exercises the sampling disagreement; the conformed pair, repaired
-- through the producer utility, must leave zero such samples.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local GxRenderer = require("libs.nds.src.love.GxRenderer")
local Matrix4 = require("libs.math.src.Matrix4")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
local VertexFormat = require("libs.assets.src.VertexFormat")

local T = {}

local CONFORMER_MODULE = "romdump.src.digest.TerrainBoundaryConformer"

local function conformer()
  local ok, mod = pcall(require, CONFORMER_MODULE)
  Assert.isTrue(
    ok and type(mod) == "table" and type(mod.conform) == "function",
    "terrain boundary repair is missing: the conformed seam cannot be produced"
  )
  return mod --[[@as table]]
end

local IDENTITY = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
local IDENTITY_NORMAL = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function zeroFog()
  local table32 = {}
  for i = 1, 32 do
    table32[i] = 0
  end
  return { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = table32 }
end

local function V(x, y, z)
  return {
    x = x,
    y = y,
    z = z,
    u = 0,
    v = 0,
    nx = 0,
    ny = 0,
    nz = 1,
    r = 255,
    g = 255,
    b = 255,
    a = 255,
    colorSource = 0,
  }
end

local function batch(vertices, indices, materialIndex)
  return {
    nodeIndex = 0,
    materialIndex = materialIndex,
    shapeIndex = 0,
    polygonAttrRaw = 0x001F00C1,
    transformMode = "static",
    vertices = vertices,
    indices = indices,
  }
end

-- The deliberate T-seam on the y=0 ground plane in tile units: the left
-- batch breaks the shared span x=0 at P=(0,0,0.5) while the right batch
-- spans it whole. Rendered under a tilted perspective camera, the span
-- projects to a long near-vertical screen line, so differently segmented but
-- collinear edges can disagree at isolated sample centers.
local function seamBatches()
  local left = batch({
    V(-8, 0, -4),
    V(0, 0, -4),
    V(0, 0, 0.5),
    V(-8, 0, 0.5),
    V(0, 0, 4),
    V(-8, 0, 4),
  }, { 0, 1, 2, 0, 2, 3, 3, 2, 4, 3, 4, 5 }, 0)
  local right = batch({
    V(0, 0, -4),
    V(8, 0, -4),
    V(8, 0, 4),
    V(0, 0, 4),
  }, { 0, 1, 2, 0, 2, 3 }, 1)
  return { left, right }
end

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[deepcopy(k)] = deepcopy(v)
  end
  return out
end

local function loveVertices(compiled)
  local flat = {}
  for _, i in ipairs(compiled.indices) do
    local v = compiled.vertices[i + 1]
    flat[#flat + 1] = {
      v.x,
      v.y,
      v.z,
      v.u,
      v.v,
      v.nx,
      v.ny,
      v.nz,
      v.r / 255,
      v.g / 255,
      v.b / 255,
      v.a / 255,
      v.colorSource,
    }
  end
  return flat
end

local function drawItem(mesh)
  return {
    mesh = mesh,
    material = { texMatrix = { 1, 0, 0, 0, 1, 0, 0, 0, 1 } },
    transform = IDENTITY,
    modelNormal = IDENTITY_NORMAL,
    center = { 0, 0, 0 },
    alphaClass = "opaque",
    cullMode = "none",
    polygonAlpha = 1.0,
    polygonMode = "modulation",
    polygonId = 0,
    lightMask = 1,
    fogEnabled = false,
    projection = nil, -- filled per frame below
  }
end

local function isRear(r)
  return r >= 0.99
end

-- Counts rear-plane samples fully enclosed in drawn terrain inside a band
-- around the seam column, staying clear of the screen borders.
local function countEnclosedRear(stateImg, w, h)
  local count = 0
  local cx = math.floor(w / 2)
  for x = cx - 14, cx + 14 do
    for y = 24, h - 25 do
      local r = stateImg:getPixel(x, y)
      if isRear(r) then
        local enclosed = true
        for ox = -1, 1 do
          for oy = -1, 1 do
            if (ox ~= 0 or oy ~= 0) and isRear(stateImg:getPixel(x + ox, y + oy)) then
              enclosed = false
              break
            end
          end
          if not enclosed then
            break
          end
        end
        if enclosed then
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Renders the batch pair across a subpixel camera sweep and totals the
-- enclosed rear-plane samples. Returns the total plus per-scale totals.
local function sweep(scope, batches, scale)
  local renderer = scope:own(GxRenderer.new({ worldRasterScale = scale }))
  local meshes = {}
  for _, compiled in ipairs(batches) do
    meshes[#meshes + 1] =
      scope:own(love.graphics.newMesh(VertexFormat.LAYOUT, loveVertices(compiled), "triangles", "static"))
  end
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })
  local scratch = { opaque = {}, cutout = {}, mixedOpaque = {}, wireframe = {}, blended = {} }
  local projection = Matrix4.perspective(math.rad(30), 1280 / 720, 1, 100)

  local items = {}
  for _, mesh in ipairs(meshes) do
    local item = drawItem(mesh)
    item.projection = projection
    items[#items + 1] = item
  end

  local function frame(dx, dz)
    local eye = { 0 + dx, 9, 13 + dz }
    local target = { 0 + dx, 0, -1 + dz }
    local view = Matrix4.lookAt(eye, target, { 0, 1, 0 })
    local queue = RenderQueue.buildInto({ items }, view, scratch)
    renderer:draw({
      edgeColors = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 },
      fog = zeroFog(),
      viewMatrix = view,
      cameraZoom = 1,
      worldProjection = projection,
      billboardProjection = projection,
      queue = queue,
      viewport = viewport,
    })
  end

  frame(0, 0)
  local total = 0
  for kx = -4, 4 do
    for _, kz in ipairs({ -0.5, 0, 0.5 }) do
      frame(kx * 0.012, kz * 0.012)
      local stateImg = renderer.renderState:newImageData()
      total = total + countEnclosedRear(stateImg, renderer.stateW, renderer.stateH)
      stateImg:release()
    end
  end
  return total
end

function T.unconformed_control_contains_a_hole(scope)
  local holes1 = sweep(scope, seamBatches(), 1)
  local holes3 = sweep(scope, seamBatches(), 3)
  Assert.isTrue(
    holes1 + holes3 >= 1,
    "the control seam must drop at least one enclosed sample (scale1=" .. holes1 .. " scale3=" .. holes3 .. ")"
  )
end

-- Each batch alone is internally watertight, so control holes come from the
-- cross-batch seam disagreement rather than degenerate single geometry.
function T.single_batches_cover_without_holes(scope)
  local batches = seamBatches()
  for index, single in ipairs(batches) do
    Assert.equal(sweep(scope, { single }, 1), 0, "batch " .. index .. " alone leaves no hole at scale 1")
    Assert.equal(sweep(scope, { single }, 3), 0, "batch " .. index .. " alone leaves no hole at scale 3")
  end
end

function T.conformed_seam_leaves_no_holes(scope)
  local repaired = conformer().conform(deepcopy(seamBatches()), { role = "map", modelName = "seam_fixture" })
    or seamBatches()
  local holes1 = sweep(scope, repaired, 1)
  local holes3 = sweep(scope, repaired, 3)
  Assert.equal(holes1, 0, "conformed seam leaves no enclosed rear-plane sample at scale 1")
  Assert.equal(holes3, 0, "conformed seam leaves no enclosed rear-plane sample at scale 3")
end

return GraphicsSmoke.suite(T)
