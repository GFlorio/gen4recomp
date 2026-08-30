-- ScriptDialogueHost tests: buffered text values resolve through the world
-- (an integer backed by a variable renders its numeric value, never its
-- identifier), unsupported buffered text forms are attributed faults rather
-- than visible markers, and the message-bank error codes flow through.

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
  local provider = opts.provider or assert(FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542) })))
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
    },
  }
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
        return 0
      end,
    },
    world = opts.world,
    frameIndex = opts.frameIndex,
  }),
    controller
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

return { tests = T }
