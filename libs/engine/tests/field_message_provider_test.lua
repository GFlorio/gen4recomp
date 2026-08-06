-- Message provider tests over a FakeCache: bank lifetime, immutable templates,
-- substitution formatting, and eviction (spec sections 14.1-14.3).

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function bankArtifact(bankId, messageCount)
  local messages = {}
  for id = 0, messageCount - 1 do
    messages[id] = {
      id = id,
      raw = { 0xFFFF },
      text = string.char(48 + id),
      tokens = {
        { kind = "glyph", code = 0x0121 + id, text = string.char(48 + id), raw = { 0x0121 + id } },
        { kind = "eos", raw = { 0xFFFF } },
      },
    }
  end
  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = messageCount,
    source = { narc = "NARC_msgdata_msg", memberId = bankId, memberSha1 = "synthetic" },
    messages = messages,
  }
end

local function cacheWith(banks)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  for bankId, artifact in pairs(banks) do
    cache:writeLua(FieldMessageCache.bankPath(bankId), artifact)
  end
  return cache
end

function T.acquire_pins_bank_and_release_evicts()
  local cache = cacheWith({ [542] = bankArtifact(542, 2), [543] = bankArtifact(543, 2) })
  local provider = FieldMessageProvider.new(cache, { maxCachedBanks = 2 })
  local bank = provider:acquireBank(542)
  Assert.equal(bank.bankId, 542)
  Assert.equal(provider:stats().loads, 1)
  local again = provider:acquireBank(542)
  Assert.equal(again, bank) -- same artifact, no reload
  Assert.equal(provider:stats().hits, 1)
  provider:releaseBank(542)
  provider:releaseBank(542)
  Assert.equal(provider:stats().references, 0)
end

function T.get_returns_immutable_templates_and_bounds_errors()
  local provider = FieldMessageProvider.new(cacheWith({ [543] = bankArtifact(543, 3) }))
  provider:acquireBank(543)
  local template = provider:get(543, 1)
  Assert.equal(template.bankId, 543)
  Assert.equal(template.messageId, 1)
  Assert.equal(template.text, "1") -- modder-facing text rides on the template
  Assert.equal(template.tokens[1].kind, "glyph")

  local missing, err = provider:get(543, 9)
  Assert.isNil(missing)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MESSAGE_ID_OUT_OF_RANGE")

  local unacquired, unacquiredErr = provider:get(542, 0)
  Assert.isNil(unacquired)
  Assert.equal(unacquiredErr.code, "MESSAGE_BANK_NOT_ACQUIRED")
end

function T.missing_bank_artifact_is_typed()
  local provider = FieldMessageProvider.new(cacheWith({}))
  local bank, err = provider:acquireBank(542)
  Assert.isNil(bank)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "MESSAGE_BANK_MISSING")
end

function T.format_substitutes_before_wrapping_and_never_mutates()
  local provider = FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542, 1) }))
  provider:acquireBank(542)
  local template = provider:get(542, 0)
  local context = { playerName = "GOLD" }
  local fontDef = {
    charmap = {
      ["G"] = 0x0131, ["O"] = 0x013B, ["L"] = 0x0138, ["D"] = 0x012E,
    },
  }
  local resolvers = {
    [0x0103] = function(control, args, ctx)
      return FieldMessageProvider.asciiGlyphTokens(ctx.playerName, fontDef)
    end,
  }
  local formatted = provider:format(template, context, resolvers)
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  Assert.equal(formatted.messageId, 0)
  Assert.equal(formatted.text, "0")

  -- A substitution token spliced in stays glyph-kind and ordered.
  local withSub = provider:format({
    bankId = 542,
    messageId = 0,
    text = "{STRVAR_1 3, 0, 0}",
    tokens = {
      { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }, context, resolvers)
  Assert.equal(#withSub.tokens, 5) -- G O L D + eos
  Assert.equal(withSub.tokens[1].text, "G")
  Assert.equal(withSub.tokens[4].text, "D")
  -- The formatted asset carries the substituted display text.
  Assert.equal(withSub.text, "GOLD")

  -- The template is untouched by formatting.
  Assert.equal(#template.tokens, 2)
end

function T.unresolved_substitution_stays_visible_and_traced()
  local provider = FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542, 1) }))
  local tokens = {
    { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local formatted = provider:format({ bankId = 542, messageId = 0, tokens = tokens }, {})
  Assert.isTrue(formatted.hadUnresolvedSubstitutions)
  Assert.equal(formatted.tokens[1].kind, "substitution")
  Assert.equal(formatted.tokens[1].control, 0x0103)
end

function T.ascii_glyph_tokens_cover_the_demo_name()
  -- The text->code mapping comes from the generated font definition's
  -- charmap metadata, never from a runtime reference import.
  local fontDef = { charmap = { ["G"] = 0x0131, ["O"] = 0x013B, ["L"] = 0x0138,
    ["D"] = 0x012E, ["é"] = 0x0188 } }
  local tokens = assert(FieldMessageProvider.asciiGlyphTokens("GOLD", fontDef))
  Assert.equal(#tokens, 4)
  Assert.equal(tokens[1].code, 0x0131) -- 'G'
  Assert.equal(tokens[4].code, 0x012E) -- 'D'
  local bad, err = FieldMessageProvider.asciiGlyphTokens("GOLD!", fontDef)
  Assert.isNil(bad)
  Assert.equal(err.code, "MESSAGE_SUBSTITUTION_UNRESOLVED")
  local accented = assert(FieldMessageProvider.asciiGlyphTokens("é", fontDef))
  Assert.equal(accented[1].code, 0x0188)
end

function T.bounded_lru_evicts_only_unreferenced_banks()
  local cache = cacheWith({
    [542] = bankArtifact(542, 1), [543] = bankArtifact(543, 1), [544] = bankArtifact(544, 1),
  })
  local provider = FieldMessageProvider.new(cache, { maxCachedBanks = 2 })
  provider:acquireBank(542)
  provider:acquireBank(543)
  provider:releaseBank(542)
  provider:releaseBank(543)
  provider:acquireBank(544) -- evicts 542 (LRU, zero references)
  Assert.equal(provider:stats().live, 2)
  Assert.equal(provider:stats().disposals, 1)
  local missing, err = provider:get(542, 0)
  Assert.isNil(missing)
  Assert.equal(err.code, "MESSAGE_BANK_NOT_ACQUIRED")

  -- A referenced bank is never evicted: with 544 released, re-acquiring 542
  -- evicts 543, and re-acquiring 543 evicts 544.
  provider:releaseBank(544)
  provider:acquireBank(542)
  Assert.equal(provider:stats().live, 2)
  provider:acquireBank(543)
  Assert.equal(provider:stats().live, 2)
  provider:releaseBank(543)
  Assert.equal(provider:stats().references, 1) -- only 542 still referenced
  Assert.equal(provider:stats().live, 2)
end

function T.dispose_releases_everything()
  local provider = FieldMessageProvider.new(cacheWith({ [542] = bankArtifact(542, 1) }))
  provider:acquireBank(542)
  provider:dispose()
  Assert.equal(provider:stats().live, 0)
end

return T
