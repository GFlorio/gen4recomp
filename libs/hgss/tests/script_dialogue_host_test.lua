-- ScriptDialogueHost tests: buffered text values resolve through the world
-- (an integer backed by a variable renders its numeric value, never its
-- identifier; the opposite-protagonist name resolves from the generated name
-- bank selected by the player profile gender with scoped bank ownership),
-- unsupported buffered text forms are attributed faults rather than visible
-- markers, and the message-bank error codes flow through.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptDialogueHost = require("libs.hgss.src.script.ScriptDialogueHost")
local FieldMessageProvider = require("libs.hgss.src.field.FieldMessageProvider")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function bankArtifact(bankId)
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = 1,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = {
      [0] = {
        id = 0,
        raw = { 0xFFFE, 0x0100, 0x0002, 0, 0, 0xFFFF },
        text = "{STRVAR_1 0, 0, 0}",
        tokens = {
          { kind = "substitution", control = 0x0100, args = { 0, 0 }, raw = { 0xFFFE, 0x0100, 0x0002, 0, 0 } },
          { kind = "eos", raw = { 0xFFFF } },
        },
      },
    },
  }
end

-- A name-bank fixture in the shape the generated message cache publishes:
-- plain glyph text plus a terminal eos, addressable by message id.
local function glyphTokensFor(word)
  local tokens = {}
  for i = 1, #word do
    local ch = word:sub(i, i)
    tokens[#tokens + 1] = { kind = "glyph", code = 0x0400 + i, text = ch, raw = { 0x0400 + i } }
  end
  tokens[#tokens + 1] = { kind = "eos", raw = { 0xFFFF } }
  return tokens
end

local function nameBankArtifact(bankId, zeroName, oneName)
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = 2,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = {
      [0] = { id = 0, raw = {}, text = zeroName, tokens = glyphTokensFor(zeroName) },
      [1] = { id = 1, raw = {}, text = oneName, tokens = glyphTokensFor(oneName) },
    },
  }
end

-- A message fixture carrying the same substitution control at two distinct
-- slots: each occurrence must resolve from its own slot.
local function twoSlotBankArtifact(bankId)
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = 1,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = {
      [0] = {
        id = 0,
        raw = {},
        text = "a {STRVAR_1 0, 0, 0} b {STRVAR_1 1, 0, 0}",
        tokens = {
          { kind = "substitution", control = 0x0100, args = { 0, 0 }, raw = {} },
          { kind = "substitution", control = 0x0100, args = { 1, 0 }, raw = {} },
          { kind = "eos", raw = {} },
        },
      },
    },
  }
end

local function cacheWith(banks)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for bankId, artifact in pairs(banks) do
    cache:writeLua(FieldMessageCache.bankPath(bankId), artifact)
  end
  return cache
end

local function host(opts)
  opts = opts or {}
  local provider = opts.provider
    or assert(
      FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542), [445] = nameBankArtifact(445, "Ethan", "Lyra") }))
    )
  local controller = {
    open = function(self, request)
      self.request = request
    end,
    close = function(self)
      self.request = nil
    end,
    isModal = function(self)
      return self.request ~= nil
    end,
    status = function()
      return { state = "WAITING_CLOSE", pageIndex = 1, revealedGlyphs = 1 }
    end,
  }
  local fontDef = {
    charmap = {
      ["1"] = 0x0101,
      ["2"] = 0x0102,
      ["3"] = 0x0103,
      ["4"] = 0x0104,
      ["5"] = 0x0105,
      ["6"] = 0x0106,
      ["7"] = 0x0107,
      ["8"] = 0x0108,
      ["9"] = 0x0109,
      ["0"] = 0x0110,
      -- The name fixtures resolve through the same text parser as the
      -- runtime, so every letter of the player and counterpart names needs
      -- a field glyph here.
      ["G"] = 0x0111,
      ["o"] = 0x0112,
      ["l"] = 0x0113,
      ["d"] = 0x0114,
      ["L"] = 0x0115,
      ["y"] = 0x0116,
      ["r"] = 0x0117,
      ["a"] = 0x0118,
      ["E"] = 0x0119,
      ["t"] = 0x011A,
      ["h"] = 0x011B,
      ["n"] = 0x011C,
    },
  }
  local gender = opts.gender or 0
  return ScriptDialogueHost.new({
    controller = controller,
    provider = provider,
    layout = function(formatted)
      return formatted
    end,
    fontDef = fontDef,
    player = {
      name = function()
        return "Gold"
      end,
      gender = function()
        return gender
      end,
    },
    world = opts.world,
    frameIndex = opts.frameIndex,
  }),
    controller,
    provider
end

-- An integer text value backed by a variable renders the variable's numeric
-- value, not its identifier.
function T.integer_text_value_renders_the_variable_value()
  local world = {
    getVar = function(_, id)
      assert(id == "VAR_COINS")
      return 42
    end,
  }
  local h = host({ world = world })
  h:openMessage({})
  h:startPrint("msg.hgss.0542.00000", { [0] = { text = "integer", value = { value = "var", id = "VAR_COINS" } } })
  local hostObject = h --[[@as { _controller: { request: { message: { text: string } }|nil } }]]
  local text = hostObject._controller.request.message.text
  Assert.equal(text, "42")
end

-- The dialogue request carries the player-selected HGSS user-frame index,
-- captured at open time from the injected player options: every print the
-- host starts stamps the same frame, and a host without options starts
-- prints without one rather than inventing a frame.
function T.start_print_stamps_the_player_frame_on_the_request()
  local world = {
    getVar = function()
      return 42
    end,
  }
  local binding = { [0] = { text = "integer", value = { value = "var", id = "VAR_COINS" } } }
  local h = host({ frameIndex = 4, world = world })
  h:openMessage({})
  h:startPrint("msg.hgss.0542.00000", binding)
  local hostObject = h --[[@as { _controller: { request: { frameIndex: number|nil }|nil } }]]
  Assert.equal(hostObject._controller.request.frameIndex, 4)

  local noFrameHost = host({ world = world })
  noFrameHost:openMessage({})
  noFrameHost:startPrint("msg.hgss.0542.00000", binding)
  local noFrameObject = noFrameHost --[[@as { _controller: { request: { frameIndex: number|nil }|nil } }]]
  Assert.isNil(noFrameObject._controller.request.frameIndex)
end

-- A buffered text form the host does not implement is an attributed fault,
-- never a marker left visible in the stream.
function T.unsupported_text_form_faults()
  local world = {
    getVar = function()
      return 0
    end,
  }
  local h = host({ world = world })
  h:openMessage({})
  local err = Assert.throws(function()
    h:startPrint("msg.hgss.0542.00000", { [0] = { text = "rival_name" } })
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_UNSUPPORTED_REACHABLE")
end

-- A non-erasing close is an attributed fault; the message-bank error codes
-- flow through unchanged.
function T.close_and_bank_errors_are_attributed()
  local h = host({})
  local err = Assert.throws(function()
    h:close(false)
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_SERVICE_MISSING")
  local bankErr = Assert.throws(function()
    h:resolveMessage("msg.hgss.9999.00000", {}, {})
  end)
  Assert.isTrue(Errors.is(bankErr))
  Assert.equal(bankErr.code, "MESSAGE_BANK_MISSING")
end

-- The same substitution control at two distinct slots resolves each
-- occurrence from its own slot: the resolver must read the slot from the
-- token's own args, never from the first occurrence.
function T.same_control_at_two_slots_resolves_each_from_its_own_slot()
  local world = {
    getVar = function(_, id)
      assert(id == "VAR_A" or id == "VAR_B")
      return id == "VAR_A" and 1 or 2
    end,
  }
  local provider = assert(FieldMessageProvider.new(cacheWith({ [543] = twoSlotBankArtifact(543) })))
  local h = host({ world = world, provider = provider })
  local formatted = h:resolveMessage("msg.hgss.0543.00000", {
    [0] = { text = "integer", value = { value = "var", id = "VAR_A" } },
    [1] = { text = "integer", value = { value = "var", id = "VAR_B" } },
  }, {})
  Assert.equal(formatted.text, "12", "each occurrence resolves from its own slot")
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
end

-- A message with an unresolvable substitution fails explicitly instead of
-- reaching the UI partially formatted.
function T.unresolved_substitution_fails_explicitly()
  local h = host({})
  local err = Assert.throws(function()
    h:resolveMessage("msg.hgss.0542.00000", {}, {})
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "SCRIPT_INVALID_REFERENCE")
  Assert.equal(err.context.bankId, 542)
  Assert.equal(err.context.messageId, 0)
end

-- The opposite-protagonist name comes from the generated name bank selected
-- by the player profile gender: a male player reads message 1.
function T.friend_name_resolves_to_the_male_counterpart_name_for_a_male_player()
  local h = host({ gender = 0 })
  local formatted = h:resolveMessage("msg.hgss.0542.00000", { [0] = { text = "friend_name" } }, {})
  Assert.equal(formatted.text, "Lyra")
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  -- Only replacement glyphs splice into the host template: the name bank's
  -- own terminal marker must not leak into the formatted stream.
  local eosCount = 0
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "eos" then
      eosCount = eosCount + 1
    end
  end
  Assert.equal(eosCount, 1, "exactly the host template's own terminal marker survives")
  Assert.equal(formatted.tokens[#formatted.tokens].kind, "eos", "the terminal marker stays terminal")
end

-- A female player reads message 0 instead.
function T.friend_name_resolves_to_the_female_counterpart_name_for_a_female_player()
  local h = host({ gender = 1 })
  local formatted = h:resolveMessage("msg.hgss.0542.00000", { [0] = { text = "friend_name" } }, {})
  Assert.equal(formatted.text, "Ethan")
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
end

-- The nested name-bank acquisition is scoped: after a successful resolution
-- the provider holds no more references than before it.
function T.friend_name_resolution_releases_the_name_bank()
  local _, _, provider = host({})
  local before = provider:stats().references
  for _, gender in ipairs({ 0, 1 }) do
    local h = host({ provider = provider, gender = gender })
    h:resolveMessage("msg.hgss.0542.00000", { [0] = { text = "friend_name" } }, {})
  end
  Assert.equal(provider:stats().references, before, "the name bank reference must be released")
end

-- A failure while reading the name bank still releases it before the
-- original fault reaches the caller: here the counterpart name carries a
-- character with no field glyph, so substitution parsing fails.
function T.failed_friend_name_read_releases_the_name_bank()
  local provider = assert(FieldMessageProvider.new(cacheWith({
    [542] = bankArtifact(542),
    [445] = nameBankArtifact(445, "Ethan", "Lyr~"),
  })))
  local h = host({ provider = provider, gender = 0 })
  local before = provider:stats().references
  local err = Assert.throws(function()
    h:resolveMessage("msg.hgss.0542.00000", { [0] = { text = "friend_name" } }, {})
  end)
  Assert.isTrue(Errors.is(err), "the original name-bank fault must propagate attributed")
  Assert.equal(
    err.code,
    "MESSAGE_SUBSTITUTION_UNRESOLVED",
    "the fault must come from name parsing, not a generic branch"
  )
  Assert.equal(provider:stats().references, before, "the name bank reference must be released on failure")
end

-- The player-name form keeps resolving through the player facade,
-- unchanged by the counterpart-name support.
function T.player_name_resolution_is_unchanged()
  local h = host({})
  local formatted = h:resolveMessage("msg.hgss.0542.00000", { [0] = { text = "player_name" } }, {})
  Assert.equal(formatted.text, "Gold")
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
end

return { tests = T }
