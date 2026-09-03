-- Deterministic per-fixed-tick diagnostic trace for one passive signpost
-- interaction. Each sample records the player pose, the script-start
-- identities seen so far, and the signpost presentation pair alongside the
-- wipe positions the renderer would derive from that pair at the alpha
-- extremes and midpoint. The trace samples through the production game step,
-- so a single approach, dismissal, and repeat is captured without gaps.

local FieldSignpostTheme = require("libs.hgss.src.ui.FieldSignpostTheme")

---@class SignpostTraceSamplePlayer
---@field fieldX integer
---@field fieldZ integer
---@field facing string
---@field motion string

---@class SignpostTraceSampleSignpost
---@field active boolean
---@field command string
---@field previousLogicalYOffset integer
---@field logicalYOffset integer

---@class SignpostTraceSample
---@field tick integer|nil
---@field player SignpostTraceSamplePlayer
---@field fieldLocked boolean
---@field scriptStarts string[]
---@field signpost SignpostTraceSampleSignpost
---@field wipe { alpha0: number, alphaHalf: number, alpha1: number }

---@class SignpostTrace
---@field game table
---@field samples SignpostTraceSample[]
local SignpostTrace = {}
SignpostTrace.__index = SignpostTrace

---@param game table an AcceptanceHarness game
---@return SignpostTrace
function SignpostTrace.attach(game)
  assert(type(game) == "table", "signpost trace requires an acceptance game")
  local trace = setmetatable({ game = game, samples = {} }, SignpostTrace)
  trace:sample()
  return trace
end

-- The script-start identities recorded so far, in emission order.
---@return string[]
function SignpostTrace:scriptStarts()
  local starts = {}
  for _, record in ipairs(self.game:recordsNamed("script.started")) do
    local payload = record.payload or {}
    starts[#starts + 1] = payload.scriptId or "<unknown>"
  end
  return starts
end

-- Records the current fixed-tick state without advancing the game.
function SignpostTrace:sample()
  local snapshot = self.game:snapshot()
  local status = self.game.runtime.signpost:status()
  local function wipeAt(alpha)
    local clamped = math.min(math.max(alpha, 0), 1)
    return FieldSignpostTheme.wipeY(
      status.previousLogicalYOffset + (status.logicalYOffset - status.previousLogicalYOffset) * clamped
    )
  end
  self.samples[#self.samples + 1] = {
    tick = snapshot.tick,
    player = {
      fieldX = snapshot.player.fieldX,
      fieldZ = snapshot.player.fieldZ,
      facing = snapshot.player.facing,
      motion = snapshot.player.motion,
    },
    fieldLocked = snapshot.fieldLocked,
    scriptStarts = self:scriptStarts(),
    signpost = {
      active = status.active,
      command = status.command,
      previousLogicalYOffset = status.previousLogicalYOffset,
      logicalYOffset = status.logicalYOffset,
    },
    wipe = { alpha0 = wipeAt(0), alphaHalf = wipeAt(0.5), alpha1 = wipeAt(1) },
  }
end

-- Advances exactly one production fixed tick and samples the result.
---@param input table|nil
function SignpostTrace:step(input)
  self.game:step(input)
  self:sample()
end

-- Samples every tick until the predicate observes the semantic state, so the
-- opening status sequence has no gaps. Mirrors the game's own bounded wait.
---@param label string
---@param predicate fun(snapshot: table): boolean
---@param maxTicks integer
---@return table
function SignpostTrace:advanceUntil(label, predicate, maxTicks)
  assert(type(label) == "string" and label ~= "", "trace advanceUntil label required")
  assert(type(predicate) == "function", "trace advanceUntil predicate required")
  assert(
    type(maxTicks) == "number" and maxTicks >= 0 and maxTicks == math.floor(maxTicks),
    "trace advanceUntil maxTicks must be a finite non-negative integer"
  )
  for _ = 0, maxTicks do
    local snapshot = self.game:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    self:step()
  end
  error("timed out waiting for " .. label, 2)
end

return SignpostTrace
