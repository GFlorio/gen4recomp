-- Shared fake LÖVE graphics namespace for the renderer unit suites. Tracks
-- created images and their release calls, records every draw (with its quad,
-- position, and the color at draw time), the transform stack (translate/
-- scale) and primitive calls (rectangle/polygon/print) as separate lists,
-- tracks the transform-stack depth, and holds a full settable state the
-- renderers must restore exactly. failOnQuadCall/failOnDrawCall make the Nth
-- construction/draw call raise; imageSizes supplies the created image
-- dimensions in creation order. The suites assert exactly the record shapes
-- this helper produces; the real love.graphics object is never touched.

---@class FakeGraphics
---@field images table[]
---@field draws table[]
---@field transforms table[]
---@field primitives string[]
---@field pushDepth fun(): integer
local FakeGraphics = {}

-- opts.canvas/shader/blendMode/... seed the settable state so tests can
-- verify exact restoration after a draw. The returned table is structurally
-- a love.Graphics subset plus the recording fields; call sites pass it as
-- the renderers' injectable graphics namespace.
---@param opts? { canvas?: any, shader?: any, blendMode?: any, blendAlpha?: any, depthMode?: any, depthWrite?: boolean, wireframe?: boolean, cullMode?: any, color?: number[], scissor?: number[], imageSizes?: table[], failOnQuadCall?: integer, failOnDrawCall?: integer }
function FakeGraphics.new(opts)
  opts = opts or {}
  local images = {}
  local quadCalls, drawCalls = 0, 0
  local pushDepth = 0
  local draws = {}
  local transforms = {}
  local primitives = {}
  local state = {
    canvas = opts.canvas,
    shader = opts.shader,
    blendMode = opts.blendMode,
    blendAlpha = opts.blendAlpha,
    depthMode = opts.depthMode,
    depthWrite = opts.depthWrite,
    wireframe = opts.wireframe,
    cullMode = opts.cullMode,
    color = opts.color or { 1, 1, 1, 1 },
    scissor = opts.scissor,
  }
  return {
    images = images,
    draws = draws,
    transforms = transforms,
    primitives = primitives,
    pushDepth = function()
      return pushDepth
    end,
    newImage = function()
      local size = opts.imageSizes and opts.imageSizes[#images + 1] or { 16, 16 }
      local image = {
        released = false,
        setFilter = function() end,
        getWidth = function()
          return size[1]
        end,
        getHeight = function()
          return size[2]
        end,
      }
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h, imgW, imgH)
      quadCalls = quadCalls + 1
      if opts.failOnQuadCall == quadCalls then
        error("injected newQuad failure")
      end
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    push = function()
      pushDepth = pushDepth + 1
    end,
    pop = function()
      pushDepth = pushDepth - 1
    end,
    translate = function(x, y)
      transforms[#transforms + 1] = { "translate", x, y }
    end,
    scale = function(x, y)
      transforms[#transforms + 1] = { "scale", x, y }
    end,
    setColor = function(r, g, b, a)
      state.color = { r, g, b, a }
    end,
    getColor = function()
      return state.color[1], state.color[2], state.color[3], state.color[4]
    end,
    draw = function(image, quad, x, y)
      drawCalls = drawCalls + 1
      draws[#draws + 1] = { kind = "draw", image = image, quad = quad, x = x, y = y, color = state.color }
      if opts.failOnDrawCall == drawCalls then
        error("injected draw failure")
      end
    end,
    rectangle = function()
      primitives[#primitives + 1] = "rectangle"
    end,
    polygon = function()
      primitives[#primitives + 1] = "polygon"
    end,
    print = function()
      primitives[#primitives + 1] = "print"
    end,
    getCanvas = function()
      return state.canvas
    end,
    setCanvas = function(canvas)
      state.canvas = canvas
    end,
    getShader = function()
      return state.shader
    end,
    setShader = function(shader)
      state.shader = shader
    end,
    getBlendMode = function()
      return state.blendMode, state.blendAlpha
    end,
    setBlendMode = function(mode, alpha)
      state.blendMode, state.blendAlpha = mode, alpha
    end,
    getDepthMode = function()
      return state.depthMode, state.depthWrite
    end,
    setDepthMode = function(mode, write)
      state.depthMode, state.depthWrite = mode, write
    end,
    isWireframe = function()
      return state.wireframe
    end,
    setWireframe = function(wireframe)
      state.wireframe = wireframe
    end,
    getMeshCullMode = function()
      return state.cullMode
    end,
    setMeshCullMode = function(mode)
      state.cullMode = mode
    end,
    getScissor = function()
      if not state.scissor then
        return nil
      end
      return state.scissor[1], state.scissor[2], state.scissor[3], state.scissor[4]
    end,
    setScissor = function(x, y, w, h)
      if x == nil then
        state.scissor = nil
      else
        state.scissor = { x, y, w, h }
      end
    end,
  }
end

return FakeGraphics
