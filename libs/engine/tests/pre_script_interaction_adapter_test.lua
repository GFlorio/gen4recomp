-- Headless adapter tests: the pre-script interaction client matches intents
-- to fixtures, formats real provider messages, pushes and releases the
-- temporary facing override exactly once on every terminal path, and opens
-- the modal dialogue (spec sections 13 and 21.5). The real dialogue
-- controller, provider, and layout are driven with synthetic fonts/banks, so
-- no LÖVE or ROM data is involved.

local Assert = require("tests.support.Assert")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")
local PreScriptInteractionAdapter = require("libs.engine.src.PreScriptInteractionAdapter")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

-- Synthetic font definition: every ASCII letter/digit/punctuation maps to a
-- code, and glyphs fall back to glyphs[0] for width measurement.
local function fontDef()
  local charmap = {}
  local code = 0x0121
  for c in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ,.:"):gmatch(".") do
    charmap[c] = code
    code = code + 1
  end
  return {
    schema = "g4-field-font-v1",
    fontId = 0,
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    glyphs = {
      [0] = { x = 0, y = 0, w = 16, h = 16, advance = 8, bearingX = 0, bearingY = 0 },
    },
    charmap = charmap,
  }
end

-- Bank artifact with plain and player-name-substituted messages.
local function bankArtifact(bankId)
  local def = fontDef()
  local function glyphTokens(chars)
    local tokens = {}
    for i = 1, #chars do
      local char = chars:sub(i, i)
      tokens[#tokens + 1] = {
        kind = "glyph", code = def.charmap[char], text = char, raw = { 0 },
      }
    end
    return tokens
  end
  local function message(id, chars)
    local tokens = glyphTokens(chars)
    tokens[#tokens + 1] = { kind = "eos", raw = { 0xFFFF } }
    return { id = id, raw = { 0xFFFF }, text = chars, tokens = tokens }
  end
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = 6,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = {
      [5] = message(5, "Elm preview."),
      [18] = message(18, "Aide preview."),
      [14] = message(14, "PC preview."),
      [93] = {
        id = 93,
        raw = { 0xFFFE, 0x0103, 2, 0, 0, 0xFFFF },
        text = "{STRVAR_1 3, 0, 0}",
        tokens = {
          { kind = "substitution", control = 0x0103, name = "STRVAR_1",
            args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 2, 0, 0 } },
          { kind = "eos", raw = { 0xFFFF } },
        },
      },
    },
  }
end

local function actor(objectEventId, initialFacing)
  local instance = FieldObjectActor.new({
    mapId = 61,
    sourceEvent = {
      objectEventId = objectEventId, spriteId = 99, movement = 0, type = 0,
      eventFlag = 0, scriptId = 1, facingDirectionRaw = 1,
      facingDirection = initialFacing or "south",
      x = 6, z = 5, y = 0,
    },
    visualDef = { mapModelId = 1 },
    fieldX = 6, fieldZ = 5, surfaceId = 0,
    worldX = 0, worldY = 0, worldZ = 0,
  })
  return instance
end

local function harness(opts)
  opts = opts or {}
  local def = fontDef()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldMessageCache.bankPath(opts.bankId or 543),
    bankArtifact(opts.bankId or 543))
  local provider = FieldMessageProvider.new(cache, { maxCachedBanks = 2 })
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local layout = function(message)
    return DialogueLayout.layout(message.tokens, metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines })
  end
  local dialogue = FieldDialogueController.new({ layout = layout })
  local elm = actor(0, "south")
  local aide = actor(2, "west")
  local traces = {}
  local adapter = PreScriptInteractionAdapter.new({
    dialogue = dialogue,
    provider = provider,
    layout = layout,
    fontDef = def,
    getActor = function(actorId)
      if actorId == elm.actorId then return elm end
      if actorId == aide.actorId then return aide end
      return nil
    end,
    mapMessageBank = opts.mapMessageBank or function() return 543 end,
    fixtures = opts.fixtures or {},
    trace = function(record) traces[#traces + 1] = record end,
    enabled = opts.enabled,
    unmappedMode = opts.unmappedMode,
  })
  return {
    adapter = adapter, dialogue = dialogue, provider = provider,
    elm = elm, aide = aide, traces = traces,
  }
end

local function objectIntent(overrides)
  local intent = {
    kind = "object",
    mapId = 61,
    sourceFieldX = 6, sourceFieldZ = 6, sourceSurfaceId = 0,
    targetFieldX = 6, targetFieldZ = 5,
    playerFacing = "north",
    scriptBankId = 843,
    scriptId = 1,
    object = { actorId = "map:61:object:0", objectEventId = 0, spriteId = 99 },
    background = nil,
    tick = 1,
  }
  for key, value in pairs(overrides or {}) do intent[key] = value end
  return intent
end

local function backgroundIntent(overrides)
  local intent = {
    kind = "background",
    mapId = 61,
    sourceFieldX = 4, sourceFieldZ = 4, sourceSurfaceId = 0,
    targetFieldX = 4, targetFieldZ = 3,
    playerFacing = "north",
    scriptBankId = 843,
    scriptId = 14,
    object = nil,
    background = { eventIndex = 10, type = 0, direction = 0 },
    tick = 2,
  }
  for key, value in pairs(overrides or {}) do intent[key] = value end
  return intent
end

-- Drives the open dialogue to completion with repeated Action edges and
-- returns the terminal result.
local function closeDialogue(dialogue)
  local result
  local ticks = 0
  while dialogue:isModal() and ticks < 500 do
    result = dialogue:step({ actionPressed = true })
    ticks = ticks + 1
  end
  return ticks < 500, result
end

function T.object_fixture_opens_and_releases_the_override_exactly_once()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = {
        messageBankId = 543, messageId = 5, facePlayer = true,
        substitutions = { playerName = "GOLD" },
      },
    },
  })
  local consumed = h.adapter:consume(objectIntent())
  Assert.equal(consumed, true)
  Assert.isTrue(h.dialogue:isModal())
  local status = h.dialogue:status()
  Assert.equal(status.requestId, "pre-script-map:61:object:0")
  -- The player faces north, so the actor must turn south toward the player.
  Assert.equal(h.elm.facing, "south")
  Assert.equal(h.elm.interactionFacingOverride.owner, "pre-script-dialogue")
  Assert.equal(h.elm.initialFacing, "south")

  -- The substituted player name lands in the message stream.
  local completed = nil
  h.dialogue:status()
  Assert.isTrue(closeDialogue(h.dialogue))
  Assert.isFalse(h.dialogue:isModal())
  Assert.isNil(h.elm.interactionFacingOverride, "the override is released on close")
  Assert.equal(h.elm.facing, h.elm.initialFacing, "the prior facing is restored")

  local kinds = {}
  for _, record in ipairs(h.traces) do kinds[#kinds + 1] = record.kind end
  local function count(kind)
    local n = 0
    for _, k in ipairs(kinds) do if k == kind then n = n + 1 end end
    return n
  end
  Assert.equal(count("field.actor.facing_override.push"), 1)
  Assert.equal(count("field.actor.facing_override.release"), 1)
  Assert.equal(count("field.dialogue.open"), 1)
  Assert.equal(count("field.dialogue.close"), 1)
  Assert.equal(count("field.message.bank.acquire"), 1)
  Assert.equal(h.provider:stats().references, 0, "the bank reference is released")
end

function T.player_name_substitution_flows_into_the_formatted_message()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = {
        messageBankId = 543, messageId = 93, facePlayer = false,
        substitutions = { playerName = "GOLD" },
      },
    },
  })
  h.adapter:consume(objectIntent({ object = { actorId = "map:61:object:0", objectEventId = 0, spriteId = 99 } }))
  -- The formatted message text must contain the substituted value (spec
  -- section 14.3: substitution happens before pagination).
  Assert.equal(h.dialogue._request.message.text, "GOLD")
  Assert.equal(h.dialogue:status().requestId, "pre-script-map:61:object:0")
  Assert.isTrue(closeDialogue(h.dialogue))
  Assert.equal(h.elm.interactionFacingOverride, nil, "facePlayer=false pushes no override")
end

function T.background_fixture_opens_without_touching_any_actor()
  local h = harness({
    fixtures = {
      ["map:61:background:10"] = { messageBankId = 543, messageId = 14, facePlayer = false },
    },
  })
  local consumed = h.adapter:consume(backgroundIntent())
  Assert.equal(consumed, true)
  Assert.equal(h.dialogue:status().requestId, "pre-script-map:61:background:10")
  Assert.equal(h.dialogue:status().pageCount, 1)
  Assert.isTrue(closeDialogue(h.dialogue))
  Assert.equal(h.elm.interactionFacingOverride, nil)
end

function T.bank_mismatch_raises_a_typed_error_and_opens_nothing()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
    },
    mapMessageBank = function() return 542 end,
  })
  local ok, err = pcall(h.adapter.consume, h.adapter, objectIntent())
  Assert.isFalse(ok)
  Assert.equal(err.code, "INTERACTION_BANK_MISMATCH")
  Assert.isFalse(h.dialogue:isModal())
  Assert.isNil(h.elm.interactionFacingOverride)
end

function T.unmapped_intent_opens_the_developer_diagnostic()
  local h = harness({ unmappedMode = "diagnostic" })
  local consumed = h.adapter:consume(objectIntent({ object = { actorId = "map:61:object:0", objectEventId = 0, spriteId = 99 } }))
  Assert.equal(consumed, true)
  Assert.isTrue(h.dialogue:isModal())
  Assert.equal(h.dialogue:status().requestId, "pre-script-map:61:object:0")
  Assert.equal(h.traces[1].kind, "field.interaction.unmapped")
  Assert.equal(h.traces[1].fixtureKey, "map:61:object:0")
  Assert.equal(h.traces[1].scriptId, 1)
  Assert.isTrue(closeDialogue(h.dialogue))
end

function T.unmapped_release_mode_shows_nothing_is_wired()
  local h = harness({ unmappedMode = "nothing" })
  h.adapter:consume(objectIntent({ object = { actorId = "map:61:object:0", objectEventId = 0, spriteId = 99 } }))
  Assert.isTrue(h.dialogue:isModal())
  Assert.isTrue(closeDialogue(h.dialogue))
end

function T.disabled_adapter_consumes_nothing_and_still_traces()
  local h = harness({
    enabled = false,
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
    },
  })
  local consumed = h.adapter:consume(objectIntent())
  Assert.equal(consumed, false)
  Assert.isFalse(h.dialogue:isModal())
  Assert.isNil(h.elm.interactionFacingOverride)
  Assert.equal(h.traces[1].kind, "field.interaction.adapter_disabled")
end

function T.dispose_releases_the_override_via_cancel()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
    },
  })
  h.adapter:consume(objectIntent())
  local result = h.dialogue:dispose()
  Assert.equal(result.kind, "cancel")
  Assert.isNil(h.elm.interactionFacingOverride)
  -- dispose again is a no-op; the release still happened exactly once.
  h.dialogue:dispose()
  local releases = 0
  for _, record in ipairs(h.traces) do
    if record.kind == "field.actor.facing_override.release" then releases = releases + 1 end
  end
  Assert.equal(releases, 1)
end

function T.layout_error_releases_the_override_via_error()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
    },
  })
  -- Break the layout for every message: no fallback glyph and no widths.
  local def = h.adapter.fontDef
  def.glyphs = {}
  def.charmap = {}
  local consumed = h.adapter:consume(objectIntent())
  Assert.equal(consumed, true)
  Assert.isTrue(h.dialogue:isModal(), "the malformed message still owns modal input")
  local errors = 0
  local ticks = 0
  while h.dialogue:isModal() and ticks < 500 do
    local result = h.dialogue:step({ actionPressed = true })
    if result and result.kind == "error" then errors = errors + 1 end
    ticks = ticks + 1
  end
  Assert.equal(errors, 1)
  Assert.isNil(h.elm.interactionFacingOverride, "the error path releases the override")
end

function T.open_failure_unwinds_the_override()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
      ["map:61:object:2"] = { messageBankId = 543, messageId = 18, facePlayer = true },
    },
  })
  h.adapter:consume(objectIntent())
  -- A second consume while modal cannot reach the session gate, but the
  -- adapter must still unwind the second actor's override if open() raises.
  local ok, err = pcall(h.adapter.consume, h.adapter,
    objectIntent({ object = { actorId = "map:61:object:2", objectEventId = 2, spriteId = 29 } }))
  Assert.isFalse(ok)
  Assert.equal(err.code, "DIALOGUE_ALREADY_OPEN")
  Assert.isNil(h.aide.interactionFacingOverride, "the failed open releases its override")
  Assert.equal(h.elm.interactionFacingOverride.owner, "pre-script-dialogue",
    "the first dialogue's override is untouched")
  h.dialogue:dispose()
end

function T.metadata_carries_the_immutable_intent()
  local h = harness({
    fixtures = {
      ["map:61:object:0"] = { messageBankId = 543, messageId = 5, facePlayer = true },
    },
  })
  local intent = objectIntent()
  h.adapter:consume(intent)
  -- The dialogue carries its own copy of the immutable intent, so mutating
  -- the caller's table afterwards cannot change the open request.
  intent.object.actorId = "mutated"
  Assert.equal(h.dialogue._request.metadata.interactionIntent.object.actorId, "map:61:object:0")
  local closed, result = closeDialogue(h.dialogue)
  Assert.isTrue(closed)
  Assert.equal(result.kind, "complete")
  Assert.equal(result.metadata.interactionIntent.object.actorId, "map:61:object:0")
end

return T
