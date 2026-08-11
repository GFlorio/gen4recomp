-- ScriptMenuHost tests: script builders retain their distinct message sources
-- and resolve complete controller requests without owning menu runtime state.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local ScriptMenuHost = require("libs.engine.src.script.ScriptMenuHost")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function bankArtifact(bankId, text)
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = 1,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = {
      [0] = {
        id = 0,
        raw = { 0xFFFF },
        text = text,
        tokens = { { kind = "glyph", text = text }, { kind = "eos", raw = { 0xFFFF } } },
      },
    },
  }
end

local function host()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldMessageCache.bankPath(1), bankArtifact(1, "Standard"))
  cache:writeLua(FieldMessageCache.bankPath(2), bankArtifact(2, "Script"))
  local requests = {}
  local provider = assert(FieldMessageProvider.new(cache))
  local h = ScriptMenuHost.new({
    provider = provider,
    standardMessageBank = 1,
    createMenu = function(request)
      requests[#requests + 1] = request
      return { request = request }
    end,
  })
  return h, requests, provider
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

-- Matching message IDs must still use different banks based on the original
-- builder operation, and entry result values must not become visual indexes.
function T.resolves_standard_and_script_messages_without_changing_item_values()
  local h, requests = host()
  local standardBuilder = h:beginMenu({
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 4, y = 5 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(standardBuilder, { messageId = 0, vanillaMetadata = 255, value = 42 })
  local standardMenu = h:execute(standardBuilder)
  Assert.equal(standardMenu.request.items[1].text.text, "Standard")
  Assert.equal(standardMenu.request.items[1].value, 42)
  Assert.equal(standardMenu.request.items[1].vanillaMetadata, 255)
  Assert.equal(requests[1].sourcePlacement.x, 4)

  local scriptBuilder = h:beginMenu({
    messageSource = { kind = "script", bank = 2 },
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 6, y = 7 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(scriptBuilder, { messageId = 0, vanillaMetadata = 17, value = 900 })
  local scriptMenu = h:execute(scriptBuilder)
  Assert.equal(scriptMenu.request.items[1].text.text, "Script")
  Assert.equal(scriptMenu.request.items[1].value, 900)
end

-- Operands are already resolved by semantic lowering before reaching this
-- pure bridge; their concrete values must be retained verbatim.
function T.retains_var_derived_item_operands_as_concrete_values()
  local h = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 0, y = 0 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 0, vanillaMetadata = 73, value = 401 })
  local menu = h:execute(builder)
  Assert.equal(menu.request.items[1].vanillaMetadata, 73)
  Assert.equal(menu.request.items[1].value, 401)
end

function T.publishes_semantic_choices_without_entering_the_imported_builder()
  local h, requests = host()
  local menu = h:choose({
    items = {
      { text = "Take", value = 10, metadata = { hgss = 255 } },
      { text = "Leave", value = 20 },
    },
    result = { value = "var", id = "choice" },
    cancellable = true,
    cancelValue = 20,
    initialCursor = 1,
    placement = { mode = "docked", anchor = "bottom", surface = "main" },
  })
  Assert.equal(menu.request.items[1].text.text, "Take")
  Assert.equal(menu.request.items[1].value, 10)
  Assert.equal(menu.request.items[1].metadata.hgss, 255)
  Assert.equal(requests[1].placementPreference.mode, "docked")
  Assert.equal(requests[1].initialCursor, 1)
  h:beginMenu({
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 0, y = 0 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
end

function T.semantic_choices_keep_local_text_out_of_the_vanilla_message_resolver()
  local h, requests = host()
  h._resolveText = function()
    error("local text must not use the vanilla message resolver")
  end
  h:choose({
    items = { { text = "Take", value = 10 } },
    cancellable = false,
    placement = { mode = "auto", anchor = "auto", surface = "auto" },
  })
  Assert.equal(requests[1].items[1].text.text, "Take")
end

function T.semantic_choices_keep_msg_prefixed_local_text_out_of_the_vanilla_message_resolver()
  local h, requests = host()
  h._resolveText = function()
    error("local text must not use the vanilla message resolver")
  end
  h:choose({
    items = { { text = "msg.custom", value = 10 } },
    cancellable = false,
    placement = { mode = "auto", anchor = "auto", surface = "auto" },
  })
  Assert.equal(requests[1].items[1].text.text, "msg.custom")
end

function T.semantic_choices_resolve_external_message_references()
  local h, requests = host()
  h._resolveText = function(message)
    Assert.deepEqual(message, { message = "external", bank = 2, id = 0 })
    return { text = "External" }
  end
  h:choose({
    items = { { text = { message = "external", bank = 2, id = 0 }, value = 10 } },
    cancellable = false,
    placement = { mode = "auto", anchor = "auto", surface = "auto" },
  })
  Assert.equal(requests[1].items[1].text.text, "External")
end

function T.semantic_choices_fault_before_publication_when_text_cannot_resolve()
  local h, requests = host()
  throwsCode("SCRIPT_MENU_MESSAGE_UNRESOLVED", function()
    h:choose({
      items = { { text = { message = "external", bank = 2, id = 0 }, value = 10 } },
      cancellable = false,
      placement = { mode = "auto", anchor = "auto", surface = "auto" },
    })
  end)
  Assert.equal(#requests, 0)
end

function T.rejects_builder_misuse()
  local h = host()
  throwsCode("SCRIPT_MENU_NOT_INITIALIZED", function()
    h:addItem(nil, { messageId = 0, vanillaMetadata = 0, value = 1 })
  end)
  throwsCode("SCRIPT_MENU_EMPTY", function()
    h:execute({ items = {} })
  end)
end

-- A failed lookup does not publish a partial controller request or leave the
-- provider's acquisition pinned; the builder remains script-owned until its
-- caller decides how to report the script fault.
function T.unresolved_messages_release_the_provider_without_publishing_a_menu()
  local h, requests, provider = host()
  local builder = h:beginMenu({
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 0, y = 0 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  h:addItem(builder, { messageId = 99, vanillaMetadata = 0, value = 1 })
  throwsCode("SCRIPT_MENU_MESSAGE_UNRESOLVED", function()
    h:execute(builder)
  end)
  Assert.equal(#requests, 0)
  Assert.equal(provider:stats().references, 0)
  local nextBuilder = h:beginMenu({
    messageSource = "standard",
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 0, y = 0 },
    initialCursor = 0,
    cancellable = false,
    result = "VAR_RESULT",
  })
  Assert.isTrue(nextBuilder ~= builder)
end

return T
