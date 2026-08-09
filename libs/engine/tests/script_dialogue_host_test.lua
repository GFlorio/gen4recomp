-- ScriptDialogueHost tests: buffered text values resolve through the world
-- (an integer backed by a variable renders its numeric value, never its
-- identifier), unsupported buffered text forms are attributed faults rather
-- than visible markers, and the message-bank error codes flow through.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local ScriptDialogueHost = require("libs.engine.src.script.ScriptDialogueHost")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local CacheFs = require("libs.rom.src.CacheFs")
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

local function cacheWith(banks)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for bankId, artifact in pairs(banks) do
    cache:writeLua(FieldMessageCache.bankPath(bankId), artifact)
  end
  return cache
end

local function host(opts)
  opts = opts or {}
  local provider = assert(FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542) })))
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
  local text = h._controller.request.message.text
  Assert.equal(text, "42")
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

return T
