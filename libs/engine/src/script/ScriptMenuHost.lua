-- Script menu host bridges source-faithful script menu construction to a
-- controller-ready request. It owns only the short-lived builder, resolves
-- message references through FieldMessageProvider, and has no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

---@class ScriptMenuHost
---@field private _provider FieldMessageProvider
---@field private _standardMessageBank integer
---@field private _createMenu fun(request: table): any
---@field private _standardFallback fun(messageId: integer): table|nil
---@field private _builder table|nil
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

---@param opts table { provider, standardMessageBank, createMenu, standardFallback?: fun(messageId: integer): table }
---@return ScriptMenuHost
function ScriptMenuHost.new(opts)
  assert(type(opts) == "table" and opts.provider, "script menu host requires a message provider")
  assertInteger(opts.standardMessageBank, "script menu host standard message bank")
  assert(type(opts.createMenu) == "function", "script menu host requires a menu factory")
  return setmetatable({
    _provider = opts.provider,
    _standardMessageBank = opts.standardMessageBank,
    _createMenu = opts.createMenu,
    _standardFallback = opts.standardFallback,
    _builder = nil,
  }, ScriptMenuHost)
end

-- Starts one source-faithful builder. `messageSource` deliberately retains
-- the distinction between standard/global and current-script message banks.
---@param spec table
function ScriptMenuHost:beginMenu(spec)
  if self._builder ~= nil then
    Errors.raise(ScriptErrors.SCRIPT_MENU_ALREADY_BUILDING, "a script menu is already being built")
  end
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
  self._builder = {
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

---@param item table { messageId, vanillaMetadata, value }
function ScriptMenuHost:addItem(item)
  local builder = self._builder
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
---@return any menuController
function ScriptMenuHost:execute()
  local builder = self._builder
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
  self._builder = nil
  return menu
end

return ScriptMenuHost
