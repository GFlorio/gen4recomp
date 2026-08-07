-- The temporary pre-script interaction client (spec section 13). It matches
-- an immutable InteractionIntent against the project-owned preview fixture
-- (data/manifests/pre_script_interactions.lua), formats the fixture message
-- through FieldMessageProvider, optionally pushes a temporary face-player
-- facing override on the target actor, and opens a modal dialogue. Every
-- terminal path (complete/cancel/error/dispose) releases the override and
-- the bank reference exactly once.
--
-- This module is the one construction point the next milestone replaces with
-- the field script scheduler (spec section 6.3): it never reads script
-- bytes, never mutates flags or variables, and never moves actors. Pure
-- domain module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

local PreScriptInteractionAdapter = {}
PreScriptInteractionAdapter.__index = PreScriptInteractionAdapter

local OVERRIDE_OWNER = "pre-script-dialogue"

-- Opposite of a named facing, for the temporary face-player behavior.
local OPPOSITE_FACING = { north = "south", south = "north", west = "east", east = "west" }

-- Fixture substitution kinds -> extended control. Only the player-name
-- STRVAR (0x0103, `{STRVAR_1 3, 0, 0}`) is used by the selected messages
-- (spec section 14.3); the fixture names the value, never the control.
local SUBSTITUTION_CONTROLS = {
  playerName = FieldMessageText.STRVAR_1 + 3,
}

local UNMAPPED_RELEASE_TEXT = "Nothing is wired here yet."

-- opts:
--   dialogue  FieldDialogueController (owns input while modal)
--   provider  FieldMessageProvider
--   layout    fun(formattedMessage) -> DialogueLayout.Result
--   fontDef   generated font definition (charmap for text substitution)
--   getActor  fun(actorId) -> FieldObjectActor | nil
--   mapMessageBank fun(mapId) -> messageBankId | nil
--   fixtures  project-owned preview manifest (spec section 13.2)
function PreScriptInteractionAdapter.new(opts)
  assert(type(opts) == "table" and opts.dialogue and opts.provider, "adapter services required")
  assert(type(opts.layout) == "function", "adapter requires the dialogue layout closure")
  assert(type(opts.fontDef) == "table" and type(opts.fontDef.charmap) == "table",
    "adapter requires the generated font definition")
  assert(type(opts.getActor) == "function" and type(opts.mapMessageBank) == "function",
    "adapter requires actor and map-bank lookups")
  assert(type(opts.fixtures) == "table", "adapter requires the preview fixture manifest")
  return setmetatable({
    dialogue = opts.dialogue,
    provider = opts.provider,
    layout = opts.layout,
    fontDef = opts.fontDef,
    getActor = opts.getActor,
    mapMessageBank = opts.mapMessageBank,
    fixtures = opts.fixtures,
  }, PreScriptInteractionAdapter)
end

local function fixtureKey(intent)
  if intent.kind == "object" then
    return string.format("map:%d:object:%d", intent.mapId, intent.object.objectEventId)
  end
  return string.format("map:%d:background:%d", intent.mapId, intent.background.eventIndex)
end

-- The intent is immutable by contract, but dialogue metadata must stay safe
-- even if a caller mutates its own copy (spec section 15.2: metadata is
-- immutable or copied). The intent is shallow data (one nested identity
-- table), so a two-level copy is exact.
local function copyIntent(intent)
  local copy = {}
  for key, value in pairs(intent) do
    if type(value) == "table" then
      local inner = {}
      for innerKey, innerValue in pairs(value) do inner[innerKey] = innerValue end
      copy[key] = inner
    else
      copy[key] = value
    end
  end
  return copy
end

local function requestIdFor(key)
  return "pre-script-" .. key
end

-- Formats the fixture message with the fixture's substitution values. The
-- bank is acquired and released around the format: FormattedMessage owns a
-- fresh token array, so no bank reference needs to outlive the request
-- (spec section 14.2).
function PreScriptInteractionAdapter:_formatMessage(fixture, bankId, messageId)
  local bank, bankErr = self.provider:acquireBank(bankId)
  if not bank then
    Errors.raise(bankErr and bankErr.code or "MESSAGE_BANK_MISSING",
      bankErr and bankErr.message or "message bank " .. tostring(bankId) .. " is unavailable",
      { bankId = bankId, cause = bankErr and bankErr.context or nil })
  end
  local template, templateErr = self.provider:get(bankId, messageId)
  if not template then
    self.provider:releaseBank(bankId)
    Errors.raise(templateErr and templateErr.code or "MESSAGE_ID_OUT_OF_RANGE",
      templateErr and templateErr.message or "message " .. tostring(messageId)
        .. " not in bank " .. tostring(bankId),
      { bankId = bankId, messageId = messageId,
        cause = templateErr and templateErr.context or nil })
  end
  local context = {}
  local resolvers = {}
  for name, control in pairs(SUBSTITUTION_CONTROLS) do
    local value = fixture.substitutions and fixture.substitutions[name]
    if value ~= nil then
      context[name] = value
      resolvers[control] = function()
        return FieldMessageProvider.asciiGlyphTokens(value, self.fontDef)
      end
    end
  end
  local okFormat, formatted = pcall(self.provider.format, self.provider, template, context, resolvers)
  self.provider:releaseBank(bankId)
  if not okFormat then error(formatted) end
  return formatted
end

-- Opens one request through the controller. Every request this adapter makes
-- is a modal field dialogue with cancel disabled (spec section 15.2), so the
-- shape lives here. Raises on open failure; the caller unwinds any pre-open
-- override.
function PreScriptInteractionAdapter:_openRequest(id, message, metadata)
  return self.dialogue:open({
    id = id,
    message = message,
    style = "field",
    modal = true,
    allowCancel = false,
    metadata = metadata,
  })
end

-- Unmapped behavior: a compact project-owned message (spec section 13.4)
-- shown through the same dialogue path so input ownership stays uniform.
function PreScriptInteractionAdapter:_openUnmapped(intent)
  local key = fixtureKey(intent)
  local tokens = FieldMessageText.parse(UNMAPPED_RELEASE_TEXT, self.fontDef, { eos = false })
  self:_openRequest(requestIdFor(key), {
    bankId = nil,
    messageId = nil,
    text = UNMAPPED_RELEASE_TEXT,
    tokens = tokens,
    hadUnresolvedSubstitutions = false,
  }, { interactionIntent = copyIntent(intent) })
end

-- Dispatches one immutable InteractionIntent. Returns true when the tick is
-- consumed (a dialogue opened).
function PreScriptInteractionAdapter:consume(intent)
  assert(type(intent) == "table" and type(intent.kind) == "string",
    "consume requires an InteractionIntent")

  local key = fixtureKey(intent)
  local fixture = self.fixtures[key]
  if not fixture then
    self:_openUnmapped(intent)
    return true
  end

  -- The fixture must agree with the map's generated message-bank association
  -- (spec section 13.2); a cross-bank fixture is not allowed.
  local mapBankId = self.mapMessageBank(intent.mapId)
  if fixture.messageBankId ~= mapBankId then
    Errors.raise("INTERACTION_BANK_MISMATCH",
      "fixture " .. key .. " selects message bank " .. tostring(fixture.messageBankId)
        .. " but map " .. intent.mapId .. " is associated with "
        .. tostring(mapBankId),
      { fixtureKey = key, fixtureBankId = fixture.messageBankId,
        mapId = intent.mapId, mapBankId = mapBankId })
  end

  local formatted = self:_formatMessage(fixture, fixture.messageBankId, fixture.messageId)

  -- Temporary face-player override: the actor turns toward the player for the
  -- dummy interaction and is restored on every exit path (spec section 8.8).
  local actor, token
  if fixture.facePlayer then
    actor = self.getActor(intent.object and intent.object.actorId)
    if not actor then
      Errors.raise("INTERACTION_FIXTURE_MISSING",
        "fixture " .. key .. " needs actor " .. tostring(intent.object and intent.object.actorId)
          .. " but no such actor is live",
        { fixtureKey = key, actorId = intent.object and intent.object.actorId, mapId = intent.mapId })
    end
    local facing = assert(OPPOSITE_FACING[intent.playerFacing],
      "unknown player facing " .. tostring(intent.playerFacing))
    token = actor:pushFacingOverride({ owner = OVERRIDE_OWNER, facing = facing })
  end

  local requestId = requestIdFor(key)
  local ok, handle = pcall(self._openRequest, self, requestId, formatted, {
    interactionIntent = copyIntent(intent),
    bankId = fixture.messageBankId,
    messageId = fixture.messageId,
  })
  if not ok then
    -- open() raised (e.g. a dialogue is already open): the override must not
    -- outlive the failed request.
    if token then actor:releaseFacingOverride(token) end
    error(handle)
  end

  local released = false
  local function release()
    if released then return end
    released = true
    if token then actor:releaseFacingOverride(token) end
  end
  handle:onComplete(release)
  handle:onCancel(release)
  handle:onError(release)
  return true
end

return PreScriptInteractionAdapter
