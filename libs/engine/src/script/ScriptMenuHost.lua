-- Script menu host resolves source-faithful script menu builders into
-- controller-ready requests. Builders belong to their ScriptInstance; this
-- service has no script-persistent state or love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

---@class ScriptMenuHost
---@field private _provider FieldMessageProvider
---@field private _standardMessageBank integer
---@field private _createMenu fun(request: table): any
---@field private _standardFallback fun(messageId: integer): table|nil
---@field private _resolveText fun(message: any): table|nil
local ScriptMenuHost = {}
ScriptMenuHost.__index = ScriptMenuHost

---@param value any
---@param name string
local function assertInteger(value, name)
  assert(
    type(value) == "number"
      and value == value
      and value ~= math.huge
      and value ~= -math.huge
      and value == math.floor(value),
    name .. " must be a finite integer"
  )
end

---@param source any
---@return integer
local function messageBank(self, source)
  if source == "standard" then
    return self._standardMessageBank
  end
  assert(type(source) == "table" and source.kind == "script", "menu message source is invalid")
  assertInteger(source.bank, "script menu message bank")
  return source.bank
end

---@param self ScriptMenuHost
---@param source any
---@param messageId integer
---@return table
local function resolveMessage(self, source, messageId)
  local bankId = messageBank(self, source)
  local acquired, bankErr = self._provider:acquireBank(bankId)
  if not acquired then
    local fallback = source == "standard" and self._standardFallback
    if fallback then
      return assert(fallback(messageId), "standard menu fallback returned no message")
    end
    Errors.raise(
      ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
      "menu message bank is unavailable",
      { bankId = bankId, messageId = messageId, cause = bankErr and bankErr.context }
    )
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local fallback = source == "standard" and self._standardFallback
    if fallback then
      return assert(fallback(messageId), "standard menu fallback returned no message")
    end
    Errors.raise(
      ScriptErrors.SCRIPT_MENU_MESSAGE_UNRESOLVED,
      "menu message is unavailable",
      { bankId = bankId, messageId = messageId, cause = templateErr and templateErr.context }
    )
  end
  local ok, formatted = pcall(self._provider.format, self._provider, template, {})
  self._provider:releaseBank(bankId)
  if not ok then
    error(formatted)
  end
  return formatted
end

local function resolveSemanticText(self, message)
  if type(message) == "string" and message:match("^msg%.hgss%.%d+%.%d+$") then
    return assert(self._resolveText, "semantic menu requires a vanilla message resolver")(message)
  end
  return { text = message }
end

---@param opts table { provider, standardMessageBank, createMenu, standardFallback?: fun(messageId: integer): table }
---@return ScriptMenuHost
function ScriptMenuHost.new(opts)
  assert(type(opts) == "table" and opts.provider, "script menu host requires a message provider")
  assertInteger(opts.standardMessageBank, "script menu host standard message bank")
  assert(type(opts.createMenu) == "function", "script menu host requires a menu factory")
  assert(
    opts.resolveText == nil or type(opts.resolveText) == "function",
    "script menu text resolver must be a function"
  )
  return setmetatable({
    _provider = opts.provider,
    _standardMessageBank = opts.standardMessageBank,
    _createMenu = opts.createMenu,
    _standardFallback = opts.standardFallback,
    _resolveText = opts.resolveText,
  }, ScriptMenuHost)
end

-- Publishes one semantic mod menu without entering the imported-HGSS builder
-- state. A project may supply its dialogue resolver; bare strings remain
-- useful as local text in isolated tools and tests.
---@param spec table
---@return any menuController
function ScriptMenuHost:choose(spec)
  assert(type(spec) == "table" and type(spec.items) == "table", "semantic menu specification is invalid")
  local items = {}
  for luaIndex, item in ipairs(spec.items) do
    local text = resolveSemanticText(self, item.text)
    assert(type(text) == "table", "semantic menu text resolver returned an invalid message")
    items[luaIndex] = {
      text = text,
      message = item.text,
      value = item.value,
      metadata = item.metadata,
    }
  end
  return self._createMenu({
    items = items,
    cancellable = spec.cancellable,
    cancelValue = spec.cancelValue,
    placementPreference = spec.placement,
    result = spec.result,
  })
end

-- Starts one source-faithful builder. `messageSource` deliberately retains
-- the distinction between standard/global and current-script message banks.
---@param spec table
---@return table builder
function ScriptMenuHost:beginMenu(spec)
  assert(type(spec) == "table", "script menu specification must be a table")
  messageBank(self, spec.messageSource)
  assert(type(spec.sourcePlacement) == "table", "script menu source placement is required")
  assert(spec.sourcePlacement.system == "hgss_bottom_screen_tiles", "script menu placement system is invalid")
  assertInteger(spec.sourcePlacement.x, "script menu source x")
  assertInteger(spec.sourcePlacement.y, "script menu source y")
  assertInteger(spec.initialCursor, "script menu initial cursor")
  assert(type(spec.cancellable) == "boolean", "script menu cancellable must be a boolean")
  assert(spec.result ~= nil, "script menu result target is required")
  local messageSource = spec.messageSource
  if type(messageSource) == "table" then
    messageSource = { kind = "script", bank = messageSource.bank }
  end
  return {
    messageSource = messageSource,
    sourcePlacement = {
      system = spec.sourcePlacement.system,
      x = spec.sourcePlacement.x,
      y = spec.sourcePlacement.y,
    },
    initialCursor = spec.initialCursor,
    cancellable = spec.cancellable,
    -- 0xFFFE is HGSS's list-menu cancellation result. This compatibility
    -- detail stays at the imported-script boundary; public menu APIs supply
    -- their cancellation value explicitly.
    cancelValue = spec.cancelValue or (spec.cancellable and 0xFFFE or nil),
    result = spec.result,
    items = {},
  }
end

---@param builder table imported HGSS menu builder owned by a ScriptInstance
---@param item table { messageId, vanillaMetadata, value }
function ScriptMenuHost:addItem(builder, item)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu item added without a menu builder")
  end
  assert(type(item) == "table", "script menu item must be a table")
  assertInteger(item.messageId, "script menu message id")
  assert(item.vanillaMetadata ~= nil, "script menu vanilla metadata is required")
  assert(item.value ~= nil, "script menu result value is required")
  builder.items[#builder.items + 1] = {
    text = { source = builder.messageSource, id = item.messageId },
    vanillaMetadata = item.vanillaMetadata,
    value = item.value,
  }
end

-- Resolves every builder entry before publication. Bank acquisitions are
-- released after each lookup; on any failure no controller request is made
-- and the builder remains available for diagnostic inspection by its caller.
---@param builder table imported HGSS menu builder owned by a ScriptInstance
---@return any menuController
function ScriptMenuHost:execute(builder)
  if builder == nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_NOT_INITIALIZED, "script menu executed without a menu builder")
  end
  if #builder.items == 0 then
    Errors.raise(ScriptErrors.SCRIPT_MENU_EMPTY, "script menu has no items")
  end
  local items = {}
  for luaIndex, item in ipairs(builder.items) do
    items[luaIndex] = {
      text = resolveMessage(self, item.text.source, item.text.id),
      message = item.text,
      vanillaMetadata = item.vanillaMetadata,
      value = item.value,
    }
  end
  local request = {
    items = items,
    sourcePlacement = builder.sourcePlacement,
    initialCursor = builder.initialCursor,
    cancellable = builder.cancellable,
    cancelValue = builder.cancelValue,
    result = builder.result,
  }
  local menu = self._createMenu(request)
  return menu
end

return ScriptMenuHost
