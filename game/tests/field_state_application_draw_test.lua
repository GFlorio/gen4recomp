-- FieldState's draw order: world, field/application fade, dialogue or
-- signpost attached to the world surface, the one active Start Menu or
-- Trainer Card application surface, then the developer HUD. Only the one
-- active modal surface is drawn: a menu phase never draws the card surface
-- or the world-attached dialogue/signpost, and an application phase never
-- draws the menu. The application fade covers the surface being transitioned
-- (the world viewport plus the Start Menu placement frame), so an auxiliary
-- menu surface can never stay visible while only the world viewport goes
-- black. The Start Menu surface renders through the StartMenuLayout record
-- resolved for the current topology -- the same pure derivation the host
-- maps hit-test points through.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local StartMenuLayout = require("libs.engine.src.StartMenuLayout")

local T = {}

-- One 640x480 world display: the placement record this topology resolves is
-- { frame = {0,0,640,480}, scale = 2.5 }, mirroring the component window.
local function worldTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
end

-- A dual-display topology (world left, auxiliary right) whose placement
-- record lies outside the world viewport, so the application fade's union
-- coverage is observable.
local function dualTopology()
  return ScreenTopology.dualDisplay({
    id = "primary",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = false,
    role = "world",
  }, {
    id = "auxiliary",
    rect = { x = 256, y = 0, width = 256, height = 192 },
    touch = false,
    role = "auxiliary",
  })
end

-- A recording fake renderer: every draw appends its label and arguments.
local function recordingRenderer(label, sink)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
  }
end

-- Spies on the real love.graphics rectangle/print/setColor calls so the
-- fade and HUD primitives are observable in call order with their colors.
local function spyGraphics(sink)
  local realRectangle, realPrint, realSetColor = love.graphics.rectangle, love.graphics.print, love.graphics.setColor
  local color = { 1, 1, 1, 1 }
  love.graphics.setColor = function(r, g, b, a)
    color = { r, g, b, a }
    realSetColor(r, g, b, a)
  end
  love.graphics.rectangle = function(mode, x, y, w, h)
    sink[#sink + 1] = { "rect", color[1], color[2], color[3], color[4], mode, x, y, w, h }
    realRectangle(mode, x, y, w, h)
  end
  love.graphics.print = function(text, ...)
    sink[#sink + 1] = { "print", color[1], color[2], color[3], color[4], text }
    realPrint(text, ...)
  end
  return function()
    love.graphics.rectangle = realRectangle
    love.graphics.print = realPrint
    love.graphics.setColor = realSetColor
  end
end

-- A bare FieldState shaped like a live presentation state: fake renderers
-- recording into the sink, a fake runtime carrying every field draw touches,
-- and the topology provider under test. The player visual record is
-- invisible, so the actor assembly never touches a real asset provider.
---@param options { hostStatus: table, dialogueModal?: boolean, signpostModal?: boolean, development?: boolean, topology?: ScreenTopology, worldViewport?: table }
---@return FieldState state
---@return table[] sink
local function drawableState(options)
  local sink = {}
  local topology = options.topology or worldTopology()
  local worldViewport = options.worldViewport or { x = 0, y = 0, width = 640, height = 480 }
  local runtime = {
    errorText = nil,
    runtimeMap = {
      mapId = 61,
      mapSymbol = "MAP_NEW_BARK",
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
    },
    player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
    playerVisual = {
      drawRecord = function()
        return { visible = false }
      end,
    },
    actors = {
      drawRecords = function()
        return {}
      end,
    },
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
    viewport = { width = 640, height = 480, worldViewport = worldViewport },
    camera = {},
    transition = { fadeAlpha = 0 },
    dialogue = {
      isModal = function()
        return options.dialogueModal == true
      end,
    },
    signpost = {
      isModal = function()
        return options.signpostModal == true
      end,
    },
    applicationHost = {
      status = function()
        return options.hostStatus
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
  }
  local state = setmetatable({
    development = options.development == true,
    runtime = runtime,
    topologyProvider = function()
      return topology
    end,
    worldParts = {},
    renderer = recordingRenderer("world", sink),
    dialogueRenderer = recordingRenderer("dialogue", sink),
    signpostRenderer = recordingRenderer("signpost", sink),
    startMenuRenderer = recordingRenderer("menu", sink),
    trainerCardRenderer = recordingRenderer("card", sink),
    menuRenderer = recordingRenderer("script-menu", sink),
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function()
      error("no actor in this scenario is visible, so the asset lookup must not run")
    end,
  }, FieldState)
  return state, sink
end

local function labels(sink)
  local out = {}
  for _, call in ipairs(sink) do
    out[#out + 1] = call[1]
  end
  return out
end

-- Idle field: the world draws first, then the open dialogue attached to the
-- world surface, then the developer HUD. No fade, no application surface.
function T.draw_orders_world_then_dialogue_then_hud_when_the_field_is_idle()
  local state, sink =
    drawableState({ hostStatus = { phase = "closed", fadeAlpha = 0 }, dialogueModal = true, development = true })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), {
    "world",
    "dialogue",
    "rect",
    "print",
    "print",
    "print",
    "print",
  })
  local dialogueCall = sink[2]
  Assert.equal(dialogueCall[2], state.runtime.dialogue, "the dialogue renderer receives the dialogue controller")
  Assert.equal(dialogueCall[3], state.runtime.viewport, "the dialogue draws into the viewport")
  Assert.equal(#sink, 7, "no signpost, menu, card, or fade draws on an idle field")
end

-- The signpost is the world-attached surface when it owns the modal slot:
-- drawn after the world, before the HUD, with the session render alpha for
-- wipe interpolation.
function T.draw_orders_world_then_signpost_then_hud_when_the_signpost_is_modal()
  local state, sink = drawableState({ hostStatus = { phase = "closed", fadeAlpha = 0 }, signpostModal = true })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "signpost" })
  local signpostCall = sink[2]
  Assert.equal(signpostCall[2], state.runtime.signpost, "the signpost renderer receives the signpost controller")
  Assert.equal(signpostCall[3], state.runtime.viewport, "the signpost draws into the viewport")
  Assert.equal(signpostCall[4], 0.5, "the signpost renderer receives the session render alpha")
end

-- Menu phase: only the Start Menu surface is drawn, through the placement
-- record resolved for the current topology. The world-attached dialogue and
-- signpost are not drawn even if they report modal (the session's
-- at-most-one-owner assert guarantees they cannot be, so the draw path must
-- never composite them underneath the menu).
function T.menu_phase_draws_only_the_start_menu_surface_through_the_placement_record()
  local menuStatus = { cursorSlotId = 1, cursorFrameIndex = 0 }
  local state, sink = drawableState({
    hostStatus = { phase = "menu", fadeAlpha = 0, menu = menuStatus },
    dialogueModal = true,
    signpostModal = true,
  })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "menu" })
  local menuCall = sink[2]
  Assert.equal(menuCall[2], menuStatus, "the start menu renderer receives the host's menu presentation")
  local expectedLayout = StartMenuLayout.resolve(worldTopology())
  Assert.deepEqual(menuCall[3], expectedLayout, "the menu draws through the topology's placement record")
  Assert.equal(menuCall[3].surfaceId, "main")
  Assert.deepEqual(menuCall[3].frame, { x = 0, y = 0, width = 640, height = 480 })
  Assert.equal(menuCall[3].scale, 2.5)
end

-- Application phase: the world stays fully faded (fadeAlpha 1) and only the
-- Trainer Card surface draws on top; the menu, dialogue, and signpost are
-- never drawn underneath the application.
function T.application_phase_draws_only_the_card_surface_and_keeps_the_world_faded()
  local applicationStatus = { name = "GOLD", trainerId = 0 }
  local state, sink = drawableState({
    hostStatus = { phase = "application", fadeAlpha = 1, application = applicationStatus },
    signpostModal = true,
  })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "rect", "card" })
  local fadeCall = sink[2]
  Assert.deepEqual(
    { fadeCall[2], fadeCall[3], fadeCall[4], fadeCall[5] },
    { 0, 0, 0, 1 },
    "the application fade runs at the host fade alpha"
  )
  Assert.deepEqual(
    { fadeCall[6], fadeCall[7], fadeCall[8], fadeCall[9], fadeCall[10] },
    { "fill", 0, 0, 640, 480 },
    "the fade covers the world viewport"
  )
  local cardCall = sink[3]
  Assert.equal(cardCall[2], applicationStatus, "the trainer card renderer receives the host's application presentation")
  Assert.equal(cardCall[3], state.runtime.viewport, "the card draws into the viewport")
end

-- The application fade covers the surface being transitioned: on a dual
-- display the world viewport AND the auxiliary Start Menu placement frame go
-- black together, so no auxiliary menu can stay visible while only the world
-- viewport fades.
function T.the_application_fade_covers_the_world_and_the_start_menu_placement_frame()
  local state, sink = drawableState({
    hostStatus = { phase = "fading_out", fadeAlpha = 0.5 },
    topology = dualTopology(),
    worldViewport = { x = 0, y = 0, width = 256, height = 192 },
  })
  local restore = spyGraphics(sink)
  local ok, err = pcall(function()
    state:draw()
  end)
  restore()
  if not ok then
    error(err, 0)
  end

  Assert.deepEqual(labels(sink), { "world", "rect" })
  local fadeCall = sink[2]
  Assert.deepEqual(
    { fadeCall[2], fadeCall[3], fadeCall[4], fadeCall[5] },
    { 0, 0, 0, 0.5 },
    "the fade runs at the host fade alpha"
  )
  Assert.deepEqual(
    { fadeCall[6], fadeCall[7], fadeCall[8], fadeCall[9], fadeCall[10] },
    { "fill", 0, 0, 512, 192 },
    "the fade covers the world viewport and the auxiliary placement frame"
  )
  Assert.equal(#sink, 2, "no modal surface is drawn during the fade")
end

return { tests = T }
