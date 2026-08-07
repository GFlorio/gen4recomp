-- Deterministic message-bank compilation and cache readiness/rollback using a
-- synthetic encrypted bank member (spec section 21.1).

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldMessageBank = require("romdump.src.digest.FieldMessageBank")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.FieldMessageCacheWriter")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")

local T = {}

local function fixture()
  local messages = {
    { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF },
    { 0x013A, 0x0156, 0x0153, 0x014A, 0x0149, 0x0157, 0x0157, 0x0153,
      0x0156, 0x01DE, 0xFFFE, 0x0103, 0x0002, 0x0000, 0x0000, 0xFFFF },
  }
  local members = {
    [542] = FieldMessageBank.encodeForTests(messages, 0x4F2F),
    [543] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0x0131, 0x0148, 0x01DE, 0xFFFF },
    }, 0xB447),
  }
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27,
        fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId) Assert.equal(fileId, 77); return "archive-bytes" end,
    openNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { readMember = function(_, memberId)
        Assert.notNil(members[memberId])
        return members[memberId]
      end }
    end,
    metadata = function() return { sha1 = "rom-sha" } end,
    version = function() return "heartgold" end,
  }
  local function sha1(bytes)
    if bytes == members[542] then return "member-542-sha" end
    if bytes == members[543] then return "member-543-sha" end
    return "archive-sha"
  end
  return romFs, sha1, function() return "dependency-sha" end
end

function T.compiles_tokenized_lossless_banks()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.deepEqual(bundle.index.bankIds, { 542, 543 })
  Assert.equal(bundle.index.schema, FieldMessageCache.INDEX_SCHEMA)

  local bank = bundle.banks[542]
  Assert.equal(bank.schema, FieldMessageCache.SCHEMA)
  Assert.equal(bank.bankId, 542)
  Assert.equal(bank.messageCount, 2)
  Assert.equal(bank.source.memberSha1, "member-542-sha")
  Assert.deepEqual(bank.messages[0].raw,
    { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF })
  -- The asset carries the modder-facing display text beside the tokens.
  Assert.equal(bank.messages[0].text, "Wow, ")
  Assert.equal(bank.messages[1].text, "Professor {STRVAR_1 3, 0, 0}")
  Assert.equal(bank.messages[1].tokens[11].kind, "substitution")
  Assert.equal(bank.messages[1].tokens[11].control, 0x0103)
  Assert.deepEqual(bank.messages[1].tokens[11].args, { 0x0000, 0x0000 })
  Assert.equal(bank.messages[1].tokens[#bank.messages[1].tokens].kind, "eos")

  Assert.equal(bundle.dependencies.messageNarc.narcId, 27)
  Assert.equal(bundle.dependencies.bank542MemberSha1, "member-542-sha")
  Assert.equal(bundle.dependencies.bank543MemberSha1, "member-543-sha")
  Assert.equal(bundle.marker, "field-message-cache-v1:rom-sha:dependency-sha")
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(LuaWriter.encode(a.index), LuaWriter.encode(b.index))
  Assert.equal(LuaWriter.encode(a.banks[542]), LuaWriter.encode(b.banks[542]))
  Assert.equal(a.marker, b.marker)
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldMessageCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldMessageCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldMessageCache.isReady(cache, bundle.marker .. "-stale"))
  local loaded = assert(cache:loadLua(FieldMessageCache.bankPath(542)))
  Assert.equal(loaded.bankId, 542)
  Assert.equal(loaded.schema, FieldMessageCache.SCHEMA)
end

function T.writer_failure_invalidates_the_class()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("banks/0543.lua", 1, true) then error("injected") end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function() FieldMessageCacheWriter.write(cache, bundle) end)
  Assert.isFalse(cache:exists(FieldMessageCache.dir()))
end

function T.unmapped_glyph_fails_compilation_with_context()
  local messages = { { 0x0001, 0xFFFF } } -- kana code outside the selected set
  local member = FieldMessageBank.encodeForTests(messages, 0x1234)
  local romFs = {
    resolvedNarc = function() return { symbol = "NARC_msgdata_msg", alias = "messages",
      narcId = 27, fileId = 77, path = "a/0/2/7" } end,
    read = function() return "archive-bytes" end,
    openNarc = function()
      return { readMember = function() return member end }
    end,
    metadata = function() return { sha1 = "rom-sha" } end,
  }
  local bundle, err = FieldMessageCompiler.compile(romFs)
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_GLYPH_UNMAPPED")
  Assert.equal(assert(err).context.bankId, 542)
  Assert.equal(assert(err).context.messageId, 0)
end

return T
