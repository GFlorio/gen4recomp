-- A proxy of the real love.graphics that passes every setup/state call
-- straight through to the real driver but turns `draw` into a sentinel
-- failure. Injected as `MapRenderer.new({ graphics = PreRenderGraphics.new() })`,
-- it lets a test exercise an entire real render-preparation path -- shader
-- compilation, canvas allocation, MRT binding, uniform sends, depth/blend
-- state -- through genuine GPU resources, then stop at the exact call that
-- would rasterize the first primitive or the final composite. No primitive is
-- ever drawn, so the test proves preparation without asserting on pixels.
--
-- The proxy is a thin `__index` wrapper: every unoverridden name (newShader,
-- newCanvas, setCanvas, setShader, send, ...) resolves straight to the real
-- love.graphics function, called exactly as production code calls it
-- (`lg.newCanvas(w, h)`, not a method call), so no caller code needs to know
-- it is running against a proxy.

local PreRenderGraphics = {}

-- The sentinel error message `draw` raises. Callers pcall the render path and
-- assert the caught error contains this exact string.
PreRenderGraphics.PRE_RENDER_STOP = "PRE_RENDER_STOP: pre-render preflight stopped before rasterizing a primitive"

---@param real love.Graphics|nil injectable for tests of this module itself; defaults to love.graphics
---@return love.Graphics
function PreRenderGraphics.new(real)
  real = real or (love and love.graphics)
  assert(real, "PreRenderGraphics requires a real love.graphics context")
  local proxy = setmetatable({}, { __index = real })
  proxy.draw = function()
    error(PreRenderGraphics.PRE_RENDER_STOP, 2)
  end
  return proxy
end

return PreRenderGraphics
