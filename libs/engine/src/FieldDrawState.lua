-- One save/restore pair for the LÖVE graphics state the field UI renderers
-- touch: canvas, shader, blend mode, depth mode, wireframe, mesh cull mode,
-- color, and scissor. Every renderer captures the state before drawing and
-- restores it afterwards so the HUD and host overlays draw normally; this
-- module keeps that block in one place with one exact restore order. Pure
-- interface helper: no state, no love requirement at load time.

local FieldDrawState = {}

-- Captures every graphics state the renderers touch. The scissor tuple is
-- stored as a table so a cleared scissor (nil tuple) is distinguishable from
-- an active one.
---@param lg love.Graphics
---@return table
function FieldDrawState.save(lg)
  local blendMode, blendAlpha = lg.getBlendMode()
  local depthMode, depthWrite = lg.getDepthMode()
  local scissorX, scissorY, scissorW, scissorH = lg.getScissor()
  return {
    canvas = lg.getCanvas(),
    shader = lg.getShader(),
    blendMode = blendMode,
    blendAlpha = blendAlpha,
    depthMode = depthMode,
    depthWrite = depthWrite,
    wireframe = lg.isWireframe(),
    cullMode = lg.getMeshCullMode(),
    color = { lg.getColor() },
    scissor = scissorX and { scissorX, scissorY, scissorW, scissorH } or nil,
  }
end

-- Restores the exact captured state, including re-enabling a scissor that
-- was active before the draw.
---@param lg love.Graphics
---@param state table
function FieldDrawState.restore(lg, state)
  lg.setCanvas(state.canvas)
  lg.setShader(state.shader)
  if state.blendMode then
    lg.setBlendMode(state.blendMode, state.blendAlpha)
  end
  if state.depthMode then
    lg.setDepthMode(state.depthMode, state.depthWrite)
  end
  lg.setWireframe(state.wireframe)
  if state.cullMode then
    lg.setMeshCullMode(state.cullMode)
  end
  local color = state.color
  lg.setColor(color[1], color[2], color[3], color[4])
  if state.scissor then
    lg.setScissor(state.scissor[1], state.scissor[2], state.scissor[3], state.scissor[4])
  else
    lg.setScissor()
  end
end

return FieldDrawState
