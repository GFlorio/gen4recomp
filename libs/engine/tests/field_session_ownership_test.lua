local Assert = require("tests.support.Assert")
local FieldSession = require("libs.engine.src.FieldSession")

local function idleTransition()
  return {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("no warp")
    end,
  }
end

local function idleInput()
  return {
    snapshot = function()
      return {}
    end,
    uiSnapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
end

local function basePlayer(overrides)
  local p = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function(self)
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

local function makeSession(opts)
  opts = opts or {}
  local player = opts.player or basePlayer()
  local camera = opts.camera or { updateFixed = function() end }
  local actors = opts.actors or { step = function() end, syncEventStateChanges = opts.syncFn }
  local scheduler = opts.scheduler
    or {
      step = function() end,
      playerInputLocked = function()
        return false
      end,
      foregroundEnvironmentId = function()
        return nil
      end,
    }
  return FieldSession.new({
    versionId = "heartgold",
    currentMap = opts.currentMap
      or { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end },
    player = player,
    camera = camera,
    transition = opts.transition or idleTransition(),
    actors = actors,
    input = opts.input or idleInput(),
    dialogue = opts.dialogue or {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = scheduler,
    scriptClient = opts.scriptClient or {
      consume = function()
        return require("libs.engine.src.script.ScriptInteractionClient").RESULTS.blocked
      end,
    },
    menuHost = opts.menuHost or {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = opts.contextChoice or {
      isActive = function()
        return false
      end,
    },
    signpost = opts.signpost or {
      isModal = function()
        return false
      end,
    },
    applicationHost = opts.applicationHost or {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        return false
      end,
      takeReopen = function()
        return false
      end,
    },
    interactions = opts.interactions or {
      resolve = function()
        return nil
      end,
    },
    fieldEntranceIndicator = opts.fieldEntranceIndicator or { updateFixed = function() end },
    eventResolver = opts.eventResolver or {
      resolveCoordinate = function()
        return nil
      end,
      resolvePassiveSign = function()
        return nil
      end,
    },
    eventState = opts.eventState or { getVar = function() end },
    playerVisual = opts.playerVisual,
  })
end

local T = {}

function T.foreground_without_player_lock_permits_movement_but_blocks_menu_and_interaction()
  local opens = 0
  local playerMoves = 0

  local scheduler = {
    foreground = "env-foreground",
    playerLocked = false,
    step = function() end,
    playerInputLocked = function(self)
      return self.playerLocked
    end,
    foregroundEnvironmentId = function(self)
      return self.foreground
    end,
  }

  local player = basePlayer({
    updateFixed = function(self)
      playerMoves = playerMoves + 1
      return false
    end,
  })

  local interactionsResolved = 0
  local interactions = {
    resolve = function()
      interactionsResolved = interactionsResolved + 1
      return { kind = "object", object = { actorId = "map:61:object:0" } }
    end,
  }

  local session = makeSession({
    player = player,
    scheduler = scheduler,
    interactions = interactions,
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function()
        opens = opens + 1
        return true
      end,
      takeReopen = function()
        return false
      end,
    },
  })

  -- With a live foreground but no player lock, movement must not be suppressed.
  -- A held direction should reach the player movement path.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south", menuPressed = true, actionPressed = true })
  Assert.equal(playerMoves, 1, "movement must not be blocked solely by foreground ownership")
  Assert.equal(opens, 0, "Start Menu must remain blocked while any foreground owns the field")
  Assert.equal(
    interactionsResolved,
    0,
    "new foreground interactions must remain blocked while a foreground owns the field"
  )
end

function T.actor_world_continues_while_foreground_holds_the_field_and_release_tick_stays_suppressed()
  local poseAdvances = 0
  local actors = {
    step = function(self, tick)
      poseAdvances = poseAdvances + 1
      -- Synchronously apply any queued presence if present; keep as plain step for this scenario.
    end,
  }

  local scheduler = {
    playerLocked = true,
    foreground = "env-foreground",
    step = function(self)
      -- Release the player lock in the same tick the session sampled input.
      self.playerLocked = false
    end,
    playerInputLocked = function(self)
      return self.playerLocked
    end,
    foregroundEnvironmentId = function(self)
      return self.foreground
    end,
  }

  -- The session samples input before stepping the scheduler. Even though the
  -- scheduler releases the lock later in the same tick, that tick's held
  -- direction must remain suppressed.
  local playerMoves = 0
  local player = basePlayer({
    updateFixed = function(self)
      playerMoves = playerMoves + 1
      return false
    end,
  })

  local session = makeSession({
    player = player,
    scheduler = scheduler,
    actors = actors,
  })

  -- Tick 1: locked at start; scheduler releases inside the tick. Actor step must still occur.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(poseAdvances, 1, "actor fixed-time progression must continue even while foreground is locked")
  Assert.equal(playerMoves, 0, "player input sampled while locked must not leak through on release tick")

  -- Tick 2: both start and end are unlocked, so movement may proceed.
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(poseAdvances, 2, "actor step must occur on every world-advancing tick")
  Assert.equal(playerMoves, 1, "fresh input on the next tick must be allowed once unlocked")
end

return { tests = T, metadata = {} }
