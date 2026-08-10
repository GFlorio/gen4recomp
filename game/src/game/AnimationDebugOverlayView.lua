-- AnimationDebugOverlayView: the in-game rendering of the animation
-- debugging overlays (spec section 39): the AnimationDebugger snapshot
-- panel, the scene observability readout (pose-performance counters,
-- allocation counters, time band), and the world-space node-transform and
-- matrix-slot axis visualizations. The data comes from the pure
-- AnimationDebugOverlay gather; this module owns the developer keybindings,
-- the selection state, and the love.graphics rendering -- the only
-- love-dependent part of the overlay system. The key handling is a pure
-- state machine over the scene runtime and is testable headless; only the
-- draw functions touch love.graphics.
--
-- Keys (overlay enabled): F3 toggle, F4 next instance, F5 next clip,
-- P play/pause the selected clip, [ / ] seek one frame, , / . reverse /
-- forward, L loop/once, N node axes, M matrix-slot axes.

local AnimationDebugger = require("libs.engine.src.AnimationDebugger")
local AnimationDebugOverlay = require("libs.engine.src.AnimationDebugOverlay")
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local Matrix4 = require("libs.math.src.Matrix4")

---@class AnimationDebugOverlayView
---@field enabled boolean
---@field selectedIndex integer
---@field selectedClip string|nil
---@field showNodeAxes boolean
---@field showSlotAxes boolean
local AnimationDebugOverlayView = {}
AnimationDebugOverlayView.__index = AnimationDebugOverlayView

-- The axis line colors of the world-space visualizations.
local AXIS_COLORS = {
  x = { 1, 0.3, 0.3 },
  y = { 0.3, 1, 0.3 },
  z = { 0.35, 0.6, 1 },
}

-- LÖVE's KeyConstant names for punctuation vary across versions and
-- platforms; normalize the aliases to the literal characters.
local KEY_ALIASES = {
  ["left bracket"] = "[",
  ["right bracket"] = "]",
  comma = ",",
  period = ".",
}

local function normalizeKey(key)
  return KEY_ALIASES[key] or key
end

function AnimationDebugOverlayView.new()
  return setmetatable({
    enabled = false,
    selectedIndex = 0,
    selectedClip = nil,
    showNodeAxes = false,
    showSlotAxes = false,
  }, AnimationDebugOverlayView)
end

-- The instance the selection points at (clamped to the runtime's list), or
-- nil when the runtime has no animated instances.
local function selectedInstance(self, runtime)
  local instances = runtime and runtime.animatedInstances or {}
  if #instances == 0 then
    return nil
  end
  self.selectedIndex = math.min(self.selectedIndex, #instances - 1)
  return instances[self.selectedIndex + 1]
end

-- The snapshot entry of the selected clip; before a clip is selected (or
-- when the selected clip no longer plays) the first entry.
local function selectedEntry(self, instance)
  local entries = AnimationDebugger.snapshot(instance)
  if self.selectedClip then
    for _, entry in ipairs(entries) do
      if entry.clipName == self.selectedClip then
        return entry
      end
    end
  end
  return entries[1]
end

-- Cycle the selected clip through the definition's animation list.
local function nextClip(self, instance)
  local names = {}
  for _, clip in ipairs(instance.definition.animations) do
    names[#names + 1] = clip.name
  end
  if #names == 0 then
    self.selectedClip = nil
    return
  end
  local index = 1
  if self.selectedClip then
    for i, name in ipairs(names) do
      if name == self.selectedClip then
        index = i + 1
        break
      end
    end
  end
  self.selectedClip = names[((index - 1) % #names) + 1]
end

-- Handle one developer key against the scene runtime; returns true when the
-- key was consumed. Pure state machine over the AnimationDebugger controls.
---@param runtime table
---@return boolean
function AnimationDebugOverlayView:keypressed(key, runtime)
  if key == "f3" then
    self.enabled = not self.enabled
    return true
  end
  if not self.enabled then
    return false
  end
  key = normalizeKey(key)
  local instance = selectedInstance(self, runtime)
  if key == "f4" and instance then
    self.selectedIndex = (self.selectedIndex + 1) % #runtime.animatedInstances
    self.selectedClip = nil
    return true
  end
  if key == "f5" and instance then
    nextClip(self, instance)
    return true
  end
  if key == "n" then
    self.showNodeAxes = not self.showNodeAxes
    return true
  end
  if key == "m" then
    self.showSlotAxes = not self.showSlotAxes
    return true
  end
  if not instance then
    return false
  end
  local entry = selectedEntry(self, instance)
  if not entry then
    return false
  end
  if key == "p" then
    if entry.playing then
      AnimationDebugger.pause(instance, entry)
    else
      AnimationDebugger.play(instance, entry)
    end
    return true
  end
  if key == "[" or key == "]" then
    local delta = key == "[" and -1 or 1
    AnimationDebugger.seekFx(instance, entry, (entry.frame + delta) * AnimationPlayer.FRAME_UNIT)
    return true
  end
  if key == "," or key == "." then
    AnimationDebugger.setDirection(instance, entry, key == "," and -1 or 1)
    return true
  end
  if key == "l" then
    AnimationDebugger.setLoopMode(instance, entry, entry.loopMode == "loop" and "once" or "loop")
    return true
  end
  return false
end

-- ---- world-space visualizations ----

-- Project one world-space point onto the viewport rectangle (the same
-- projection path the renderer uses: camera view x projection, then the
-- NDC to pixel mapping of the scene canvas placement). nil when the point
-- is behind the camera or far outside the frustum.
local function worldToScreen(projection, view, rectangle, point)
  local vx, vy, vz = Matrix4.transformPoint(view, point[1], point[2], point[3])
  local w = projection[4] * vx + projection[8] * vy + projection[12] * vz + projection[16]
  if w == 0 then
    return nil
  end
  local nx = (projection[1] * vx + projection[5] * vy + projection[9] * vz + projection[13]) / w
  local ny = (projection[2] * vx + projection[6] * vy + projection[10] * vz + projection[14]) / w
  if nx < -1.5 or nx > 1.5 or ny < -1.5 or ny > 1.5 then
    return nil
  end
  return {
    rectangle.x + (nx * 0.5 + 0.5) * rectangle.width,
    rectangle.y + (0.5 - ny * 0.5) * rectangle.height,
  }
end

-- Draw one instance's axis segments (node or slot) against the frame's
-- camera, colored per axis. `alpha` is the camera interpolation factor of
-- the frame, the same value the renderer used for the scene.
local function drawSegments(segments, projection, view, rectangle)
  local lg = love.graphics
  for _, segment in ipairs(segments) do
    local from = worldToScreen(projection, view, rectangle, segment.from)
    local to = worldToScreen(projection, view, rectangle, segment.to)
    if from and to then
      lg.setColor(AXIS_COLORS[segment.axis])
      lg.setLineWidth(2)
      lg.line(from[1], from[2], to[1], to[2])
    end
  end
end

function AnimationDebugOverlayView:_drawAxes(runtime, camera, viewport, alpha)
  local rectangle = viewport.worldViewport
  local view = camera:view(alpha)
  local projection = camera:projection()
  for _, instance in ipairs(runtime.animatedInstances or {}) do
    if self.showNodeAxes then
      drawSegments(AnimationDebugOverlay.nodeAxisSegments(instance), projection, view, rectangle)
    end
    if self.showSlotAxes then
      drawSegments(AnimationDebugOverlay.slotAxisSegments(instance), projection, view, rectangle)
    end
  end
end

-- ---- the text panel ----

local function appendLines(lines, maxLines, ...)
  for i = 1, select("#", ...) do
    if #lines >= maxLines then
      lines[#lines + 1] = "  ... (truncated)"
      return
    end
    lines[#lines + 1] = select(i, ...)
  end
end

local function fmtVec(v)
  if not v then
    return "-"
  end
  return string.format("(%.2f, %.2f, %.2f)", v[1], v[2], v[3])
end

local function fmtAnimations(lines, maxLines, animations)
  for _, entry in ipairs(animations) do
    local roles = table.concat(entry.roles or {}, "+")
    local label = roles ~= "" and (" " .. roles) or ""
    appendLines(
      lines,
      maxLines,
      string.format(
        "    [%d] %s%s %s m%s %.2f/%d %s %s prio %d ratio %d targets %d",
        entry.slot,
        entry.clipName,
        label,
        entry.format,
        tostring(entry.memberId or "-"),
        entry.frame,
        entry.frameCount,
        entry.direction,
        entry.loopMode,
        entry.priority,
        entry.ratioFx,
        entry.boundTargets
      )
    )
  end
end

local function fmtNodes(lines, maxLines, nodes)
  for _, node in ipairs(nodes) do
    appendLines(
      lines,
      maxLines,
      string.format(
        "    n%d %s%s %s%s",
        node.index,
        node.name or "?",
        node.slot ~= nil and (" slot " .. node.slot) or "",
        fmtVec(node.translation),
        node.visible and "" or " HIDDEN"
      )
    )
  end
end

local function fmtSlots(lines, maxLines, slots)
  for _, slot in ipairs(slots) do
    appendLines(lines, maxLines, string.format("    s%d %s", slot.slot, fmtVec(slot.translation)))
  end
end

local function fmtDraws(lines, maxLines, draws)
  for _, draw in ipairs(draws) do
    appendLines(
      lines,
      maxLines,
      string.format("    %s %s %s %s", draw.meshId, draw.source, draw.transformMode, fmtVec(draw.translation))
    )
  end
end

-- Render the gathered overlay data as a text panel at the right of the
-- screen: the scene readout, the performance and allocation counters, then
-- the selected instance's animation entries, nodes, slots, and draws.
function AnimationDebugOverlayView:_drawPanel(data)
  local lg = love.graphics
  local maxLines = 34
  local lines = {
    "ANIMATION DEBUGGER  F3 off  F4 instance  F5 clip  P play/pause  [ ] seek  , . dir  L loop  N/M axes",
  }
  local scene = data.scene
  appendLines(
    lines,
    maxLines,
    string.format(
      "map %d %s  band %s  instances %d/%d models",
      scene.mapId,
      scene.mapSymbol,
      scene.timeBand,
      scene.animatedInstances,
      scene.animatedModelCount
    ),
    string.format(
      "meshes %d  textures %d  triangles %d  draws %d",
      scene.meshCount,
      scene.textureCount,
      scene.triangleCount,
      scene.drawCalls
    )
  )
  local totals = {}
  for _, phase in ipairs({ "pose", "material", "update", "bandSwap", "sync" }) do
    totals[#totals + 1] = phase .. "=" .. data.perfTotals[phase]
  end
  appendLines(lines, maxLines, "perf totals " .. table.concat(totals, " "))
  for _, row in ipairs(data.perf) do
    appendLines(lines, maxLines, string.format("  %s %s x%d %.4fs", row.key, row.phase, row.count, row.seconds))
  end
  local alloc = {}
  for _, row in ipairs(data.alloc) do
    alloc[#alloc + 1] = string.format("%s=%d(+%d)", row.site, row.total, row.last)
  end
  appendLines(lines, maxLines, "alloc " .. table.concat(alloc, " "))

  local selected = data.instances[math.min(self.selectedIndex, #data.instances - 1) + 1]
  if selected then
    appendLines(lines, maxLines, "instance " .. selected.label .. " (" .. selected.backend .. ")")
    fmtAnimations(lines, maxLines, selected.animations)
    appendLines(lines, maxLines, "  nodes")
    fmtNodes(lines, maxLines, selected.nodes)
    appendLines(lines, maxLines, "  matrix slots")
    fmtSlots(lines, maxLines, selected.slots)
    appendLines(lines, maxLines, "  draws")
    fmtDraws(lines, maxLines, selected.draws)
  end

  lg.setColor(0, 0, 0, 0.55)
  local panelWidth = lg.getWidth() - 24
  lg.rectangle("fill", lg.getWidth() - panelWidth - 12, 12, panelWidth, 15 * #lines + 12)
  lg.setColor(0.9, 0.95, 1)
  for index, line in ipairs(lines) do
    lg.print(line, lg.getWidth() - panelWidth, 20 + (index - 1) * 15)
  end
end

-- Draw the overlays for the frame: the axis visualizations first (they sit
-- on top of the rendered scene, before the text panel), then the text
-- panel. `alpha` is the camera interpolation factor the renderer used.
---@param runtime table
---@param camera table
---@param viewport table
---@param rendererStats table|nil
---@param alpha number
function AnimationDebugOverlayView:draw(runtime, camera, viewport, rendererStats, alpha)
  if not self.enabled or not runtime then
    return
  end
  if self.showNodeAxes or self.showSlotAxes then
    self:_drawAxes(runtime, camera, viewport, alpha)
  end
  self:_drawPanel(AnimationDebugOverlay.gather(runtime, rendererStats))
end

return AnimationDebugOverlayView
