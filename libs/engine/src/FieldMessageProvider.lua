-- Runtime message bank cache and formatter over the generated message
-- derived class. Banks are pre-tokenized at import time (FieldMessageCompiler);
-- this module owns bank lifetime (acquire/release, bounded LRU), immutable
-- MessageTemplate access, and substitution formatting that never mutates the
-- template. Pure module: CacheFs-shaped IO only, no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

---@class FieldMessageProvider
---@field private _cacheFs CacheFs
---@field private _maxCachedBanks integer
---@field private _banks table<integer, table>
---@field private _order integer[]
---@field private _stats table
local FieldMessageProvider = {}
FieldMessageProvider.__index = FieldMessageProvider

-- Named error codes: the provider's documented failure identity, exported so
-- callers (the script dialogue host) never duplicate the literals.
FieldMessageProvider.MESSAGE_BANK_MISSING = "MESSAGE_BANK_MISSING"
FieldMessageProvider.MESSAGE_BANK_NOT_ACQUIRED = "MESSAGE_BANK_NOT_ACQUIRED"
FieldMessageProvider.MESSAGE_ID_OUT_OF_RANGE = "MESSAGE_ID_OUT_OF_RANGE"
FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED = "MESSAGE_CONTROL_UNSUPPORTED"
FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID = "MESSAGE_CONTROL_ARGUMENT_INVALID"

---@class MessageToken
---@field kind "glyph"|"substitution"|"eos"|"line_break"|"prompt_break"|"page_break"|"focus_indicator"|"style"|"wait"|"unsupported_control"
---@field raw integer[]
---@field code integer?
---@field text string?
---@field control integer?
---@field name string?
---@field args integer[]?
---@field colorIndex integer? runtime-prepared presentation metadata on glyph tokens; not part of the raw ROM message format

---@class FieldMessageProvider.FormattedMessage
---@field bankId integer
---@field messageId integer
---@field text string
---@field tokens MessageToken[]
---@field hadUnresolvedSubstitutions boolean

---@class FieldMessageProvider.MessageTemplate
---@field bankId integer
---@field messageId integer
---@field text string
---@field raw integer[]
---@field tokens MessageToken[]

local DEFAULT_MAX_CACHED_BANKS = 4

-- COLOR's special argument values from the source printer: 100..106 store a
-- color pair for later restoration, and 0xFF swaps the active and stored pairs
-- (handled in the prepareControls pass below).
local COLOR_SAVE_BASE = 100
local COLOR_SWAP = 0xFF

---@param cacheFs table CacheFs-shaped
---@param opts table|nil
---@return FieldMessageProvider
function FieldMessageProvider.new(cacheFs, opts)
  opts = opts or {}
  assert(cacheFs and cacheFs.loadLua, "provider requires a CacheFs-shaped object")
  return setmetatable({
    _cacheFs = cacheFs,
    _maxCachedBanks = opts.maxCachedBanks or DEFAULT_MAX_CACHED_BANKS,
    _banks = {}, -- bankId -> { bank = artifact, references = n }
    _order = {}, -- bankIds most-recently-used first (eviction order)
    _stats = { loads = 0, hits = 0, disposals = 0 },
  }, FieldMessageProvider)
end

function FieldMessageProvider:stats()
  local stats = {
    loads = self._stats.loads,
    hits = self._stats.hits,
    disposals = self._stats.disposals,
    live = 0,
    references = 0,
  }
  for _, entry in pairs(self._banks) do
    stats.live = stats.live + 1
    stats.references = stats.references + entry.references
  end
  return stats
end

-- Loads the bank artifact once and pins it. Returns the bank artifact or
-- (nil, err) with MESSAGE_BANK_MISSING on an absent/corrupt cache file.
function FieldMessageProvider:acquireBank(bankId)
  local entry = self._banks[bankId]
  if entry then
    entry.references = entry.references + 1
    self:_touch(bankId)
    self._stats.hits = self._stats.hits + 1
    return entry.bank
  end
  local bank, err = self._cacheFs:loadLua(FieldMessageCache.bankPath(bankId))
  if type(bank) ~= "table" or bank.schema ~= FieldMessageCache.SCHEMA or bank.bankId ~= bankId then
    local context = { bankId = bankId, loadError = err }
    ---@cast context Errors.Context
    return nil,
      Errors.new(
        FieldMessageProvider.MESSAGE_BANK_MISSING,
        "message bank " .. tostring(bankId) .. " is unavailable in the generated cache",
        context
      )
  end
  self._banks[bankId] = { bank = bank, references = 1 }
  table.insert(self._order, 1, bankId) -- most-recently-used first
  self._stats.loads = self._stats.loads + 1
  self:_evict()
  return bank
end

function FieldMessageProvider:releaseBank(bankId)
  local entry = self._banks[bankId]
  if not entry then
    Errors.raise(
      FieldMessageProvider.MESSAGE_BANK_NOT_ACQUIRED,
      "release of unacquired message bank " .. tostring(bankId),
      { bankId = bankId }
    )
  end
  entry.references = entry.references - 1
  assert(entry.references >= 0, "message bank reference count went negative")
  if entry.references == 0 then
    self:_evict()
  end
end

-- Evicts unreferenced banks while the cache exceeds its bound, scanning from
-- least- to most-recently-used so a pinned least-recent bank cannot protect a
-- more-recent unreferenced one. Stops once within the bound or when every
-- resident is pinned: the capacity is necessarily soft then. Never reloads a
-- valid bank for every access.
function FieldMessageProvider:_evict()
  for i = #self._order, 1, -1 do
    if #self._order <= self._maxCachedBanks then
      break
    end
    local bankId = self._order[i]
    if self._banks[bankId].references == 0 then
      table.remove(self._order, i)
      self._banks[bankId] = nil
      self._stats.disposals = self._stats.disposals + 1
    end
  end
end

function FieldMessageProvider:_touch(bankId)
  local position
  for i, id in ipairs(self._order) do
    if id == bankId then
      position = i
      break
    end
  end
  if position then
    table.remove(self._order, position)
    table.insert(self._order, 1, bankId)
  end
end

-- Returns an immutable MessageTemplate for an acquired bank: the modder-
-- facing text plus the lossless token stream and raw code units. Never loads
-- on its own: bank lifetime is explicit.
function FieldMessageProvider:get(bankId, messageId)
  local entry = self._banks[bankId]
  if not entry then
    return nil,
      Errors.new(
        FieldMessageProvider.MESSAGE_BANK_NOT_ACQUIRED,
        "message bank " .. tostring(bankId) .. " is not acquired",
        { bankId = bankId }
      )
  end
  local message = entry.bank.messages[messageId]
  if not message then
    return nil,
      Errors.new(
        FieldMessageProvider.MESSAGE_ID_OUT_OF_RANGE,
        "message "
          .. tostring(messageId)
          .. " not in bank "
          .. tostring(bankId)
          .. " of "
          .. tostring(entry.bank.messageCount),
        { bankId = bankId, messageId = messageId, messageCount = entry.bank.messageCount }
      )
  end
  return {
    bankId = bankId,
    messageId = messageId,
    text = message.text,
    raw = message.raw,
    tokens = message.tokens,
  }
end

-- Raises a printer-control fault that always carries the message's source
-- identity, so no playback failure ever says only "unsupported control".
---@param code string
---@param template FieldMessageProvider.MessageTemplate
---@param token MessageToken
---@param message string
local function controlFault(code, template, token, message)
  local context = {
    bankId = template.bankId,
    messageId = template.messageId,
    control = token.control,
    name = token.name,
    args = token.args,
    kind = token.kind,
  }
  ---@cast context Errors.Context
  Errors.raise(code, message, context)
end

local function controlLabel(token)
  return token.name or (token.control and string.format("0x%04X", token.control) or tostring(token.kind))
end

-- Prepares printer-control state on an expanded runtime token stream: a pure
-- left-to-right pass that annotates every glyph with the effective colorIndex
-- (default 0; COLOR 0..6 selects a variant, 100..106 saves one for later, and
-- 0xFF swaps the active and saved colors). focus_indicator tokens must carry
-- one valid frame argument. Every other control -- wait, size/unknown style
-- families, and unsupported controls -- is a typed fault at this playback
-- boundary instead of a silent renderer no-op. Non-glyph tokens are kept by
-- reference: the prepared stream stays lossless for diagnostics and marker
-- round-tripping, and the template is never mutated.
---@param template FieldMessageProvider.MessageTemplate
---@param tokens MessageToken[]
---@return MessageToken[]
local function prepareControls(template, tokens)
  local currentColor = 0
  local savedColor = nil
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local prepared = {}
      for key, value in pairs(token) do
        prepared[key] = value
      end
      prepared.colorIndex = currentColor
      out[#out + 1] = prepared
    elseif token.kind == "focus_indicator" then
      local args = token.args or {}
      if #args ~= 1 then
        controlFault(
          FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID,
          template,
          token,
          "focus indicator " .. controlLabel(token) .. " must take exactly one frame argument"
        )
      end
      local field = args[1]
      if type(field) ~= "number" or field % 1 ~= 0 or field < 0 or field >= FieldMessageText.FOCUS_INDICATOR_COUNT then
        controlFault(
          FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID,
          template,
          token,
          "focus indicator field "
            .. tostring(field)
            .. " is outside 0.."
            .. tostring(FieldMessageText.FOCUS_INDICATOR_COUNT - 1)
        )
      end
      out[#out + 1] = token
    elseif token.kind == "style" and token.control == FieldMessageText.COLOR then
      local args = token.args or {}
      if #args ~= 1 then
        controlFault(
          FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID,
          template,
          token,
          "COLOR must take exactly one argument"
        )
      end
      local value = args[1]
      if type(value) ~= "number" or value % 1 ~= 0 then
        controlFault(
          FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID,
          template,
          token,
          "COLOR argument " .. tostring(value) .. " is not an integer"
        )
      end
      if value >= 0 and value < FieldMessageText.COLOR_VARIANT_COUNT then
        currentColor = value
      elseif value >= COLOR_SAVE_BASE and value <= COLOR_SAVE_BASE + FieldMessageText.COLOR_VARIANT_COUNT - 1 then
        savedColor = value - COLOR_SAVE_BASE
      elseif value == COLOR_SWAP then
        if savedColor ~= nil then
          local previous = currentColor
          currentColor = savedColor
          savedColor = previous
        else
          savedColor = currentColor
        end
      else
        controlFault(
          FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID,
          template,
          token,
          "COLOR argument "
            .. tostring(value)
            .. " is not 0.."
            .. tostring(FieldMessageText.COLOR_VARIANT_COUNT - 1)
            .. ", "
            .. tostring(COLOR_SAVE_BASE)
            .. ".."
            .. tostring(COLOR_SAVE_BASE + FieldMessageText.COLOR_VARIANT_COUNT - 1)
            .. ", or "
            .. string.format("0x%02X", COLOR_SWAP)
        )
      end
      out[#out + 1] = token
    elseif token.kind == "style" then
      controlFault(
        FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED,
        template,
        token,
        controlLabel(token) .. " is a style control with no playback semantics in this build"
      )
    elseif token.kind == "wait" then
      controlFault(
        FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED,
        template,
        token,
        controlLabel(token) .. " has no playback semantics in this build"
      )
    elseif token.kind == "unsupported_control" then
      controlFault(
        FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED,
        template,
        token,
        "unsupported printer control " .. controlLabel(token)
      )
    else
      -- eos, breaks, and unresolved substitutions pass through unchanged.
      out[#out + 1] = token
    end
  end
  return out
end

-- Builds a new token sequence from the template. resolvers maps extended
-- control codes to `function(control, args, context) -> replacementTokens`.
-- Replacement tokens must be glyph-kind tokens; they are spliced in verbatim
-- before printer-control preparation, so substituted glyphs inherit the color
-- active at their source position. Unresolved substitution tokens stay in the
-- stream (traced by the caller) and the result flags them.
function FieldMessageProvider:format(template, context, resolvers)
  assert(template and template.tokens, "format requires a MessageTemplate")
  context = context or {}
  local expanded = {}
  local hadUnresolved = false
  for _, token in ipairs(template.tokens) do
    if token.kind == "substitution" then
      local resolver = resolvers and resolvers[token.control]
      local replacement = resolver and resolver(token.control, token.args, context)
      if replacement then
        for _, replacementToken in ipairs(replacement) do
          expanded[#expanded + 1] = replacementToken
        end
      else
        hadUnresolved = true
        expanded[#expanded + 1] = token
      end
    else
      expanded[#expanded + 1] = token
    end
  end
  local prepared = prepareControls(template, expanded)
  return {
    bankId = template.bankId,
    messageId = template.messageId,
    text = FieldMessageText.tokensToText(prepared),
    tokens = prepared,
    hadUnresolvedSubstitutions = hadUnresolved,
  }
end

function FieldMessageProvider:dispose()
  self._banks = {}
  self._order = {}
  self._stats = { loads = 0, hits = 0, disposals = 0 }
end

-- Converts display text into glyph-kind tokens for substitution contexts such
-- as the demo player name. The text->code mapping comes from the generated
-- font definition's charmap metadata (digested at import time), so the runtime
-- never imports the raw charmap reference. No eos token is produced: the
-- replacement splices into an existing message stream. Returns nil, err with
-- MESSAGE_SUBSTITUTION_UNRESOLVED on an unmappable character.
function FieldMessageProvider.asciiGlyphTokens(text, fontDef)
  return FieldMessageText.parse(text, fontDef, { eos = false })
end

return FieldMessageProvider
