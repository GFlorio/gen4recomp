-- Runtime message bank cache and formatter over the generated message
-- derived class. Banks are pre-tokenized at import time (FieldMessageCompiler);
-- this module owns bank lifetime (acquire/release, bounded LRU), immutable
-- MessageTemplate access, and substitution formatting that never mutates the
-- template. Pure module: CacheFs-shaped IO only, no love dependency.

local Errors = require("libs.rom.src.Errors")
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

---@class MessageToken
---@field kind "glyph"|"substitution"|"eos"|"line_break"|"prompt_break"|"page_break"|"unsupported_control"
---@field raw integer[]
---@field code integer?
---@field text string?
---@field control integer?
---@field name string?
---@field args integer[]?

---@class FieldMessageProvider.FormattedMessage
---@field bankId integer
---@field messageId integer
---@field text string
---@field tokens MessageToken[]
---@field hadUnresolvedSubstitutions boolean

local DEFAULT_MAX_CACHED_BANKS = 4

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
    return nil,
      Errors.new(
        FieldMessageProvider.MESSAGE_BANK_MISSING,
        "message bank " .. tostring(bankId) .. " is unavailable in the generated cache",
        { bankId = bankId, loadError = err }
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
-- on its own: bank lifetime is explicit (spec section 14.2).
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

-- Builds a new token sequence from the template. resolvers maps extended
-- control codes to `function(control, args, context) -> replacementTokens`.
-- Replacement tokens must be glyph-kind tokens; they are spliced in verbatim.
-- Unresolved substitution tokens stay in the stream (visible markers, traced
-- by the caller) and the result flags them.
function FieldMessageProvider:format(template, context, resolvers)
  assert(template and template.tokens, "format requires a MessageTemplate")
  context = context or {}
  local tokens = {}
  local hadUnresolved = false
  for _, token in ipairs(template.tokens) do
    if token.kind == "substitution" then
      local resolver = resolvers and resolvers[token.control]
      local replacement = resolver and resolver(token.control, token.args, context)
      if replacement then
        for _, replacementToken in ipairs(replacement) do
          tokens[#tokens + 1] = replacementToken
        end
      else
        hadUnresolved = true
        tokens[#tokens + 1] = token
      end
    else
      tokens[#tokens + 1] = token
    end
  end
  return {
    bankId = template.bankId,
    messageId = template.messageId,
    text = FieldMessageText.tokensToText(tokens),
    tokens = tokens,
    hadUnresolvedSubstitutions = hadUnresolved,
  }
end

function FieldMessageProvider:dispose()
  self._banks = {}
  self._order = {}
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
