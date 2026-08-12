-- Deterministic message-bank compilation and cache readiness/rollback using a
-- synthetic encrypted bank member.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.FieldMessageBank")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local FieldMessageCacheWriter = require("romdump.src.digest.FieldMessageCacheWriter")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")

local T = {}

local function fixture()
  local messages = {
    { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF },
    {
      0x013A,
      0x0156,
      0x0153,
      0x014A,
      0x0149,
      0x0157,
      0x0157,
      0x0153,
      0x0156,
      0x01DE,
      0xFFFE,
      0x0103,
      0x0002,
      0x0000,
      0x0000,
      0xFFFF,
    },
  }
  local members = {
    [542] = FieldMessageBank.encodeForTests(messages, 0x4F2F),
    [543] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0x0131, 0x0148, 0x01DE, 0xFFFF },
    }, 0xB447),
  }
  -- The New Bark interior banks (544-549) joined the selected set with the
  -- script override slice; each fixture member is one short message.
  local interiorKeys = { 0x4C11, 0x5C22, 0x6C33, 0x7C44, 0x8C55, 0x9C66 }
  for index, bankId in ipairs({ 544, 545, 546, 547, 548, 549 }) do
    members[bankId] = FieldMessageBank.encodeForTests({
      { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
    }, interiorKeys[index])
  end
  -- Bank 191 joined the selected set with the menu-items slice; serve it the
  -- same way, one short message with its own key.
  members[191] = FieldMessageBank.encodeForTests({
    { 0x012F, 0x0150, 0x0151, 0x01DE, 0xFFFF },
  }, 0xD191)
  local romFs = {
    resolvedNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function(_, fileId)
      Assert.equal(fileId, 77)
      return "archive-bytes"
    end,
    openNarc = function(_, alias)
      Assert.equal(alias, "messages")
      return {
        readMember = function(_, memberId)
          Assert.notNil(members[memberId])
          return members[memberId]
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  local function sha1(bytes)
    for bankId, memberBytes in pairs(members) do
      if bytes == memberBytes then
        return string.format("member-%d-sha", bankId)
      end
    end
    return "archive-sha"
  end
  return romFs, sha1, function()
    return "dependency-sha"
  end
end

function T.compiles_tokenized_lossless_banks()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  Assert.deepEqual(bundle.index.bankIds, { 542, 543, 544, 545, 546, 547, 548, 549, 191 })
  Assert.equal(bundle.index.schema, FieldMessageCache.INDEX_SCHEMA)

  local bank = bundle.banks[542]
  Assert.equal(bank.schema, FieldMessageCache.SCHEMA)
  Assert.equal(bank.bankId, 542)
  Assert.equal(bank.messageCount, 2)
  Assert.equal(bank.source.memberSha1, "member-542-sha")
  Assert.deepEqual(bank.messages[0].raw, { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF })
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
  Assert.equal(bundle.dependencies.bank191MemberSha1, "member-191-sha")
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
    if path:find("banks/0543.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local cache = CacheFs.forVersion("heartgold", backend)
  Assert.throws(function()
    FieldMessageCacheWriter.write(cache, bundle)
  end)
  Assert.isFalse(cache:exists(FieldMessageCache.dir()))
end

function T.failed_rebuild_preserves_the_previous_messages()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldMessageCacheWriter.write(cache, first)
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("banks/0543.lua", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldMessageCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldMessageCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldMessageCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldMessageCache.isReady(cache, first.marker), "the previous messages remain ready")
  Assert.equal(cache:read(FieldMessageCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-messages"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldMessageCacheWriter.write(cache, second)
  Assert.isTrue(FieldMessageCache.isReady(cache, second.marker), "a retry publishes the new messages")
end

function T.unmapped_glyph_fails_compilation_with_context()
  local messages = { { 0x0001, 0xFFFF } } -- kana code outside the selected set
  local member = FieldMessageBank.encodeForTests(messages, 0x1234)
  local romFs = {
    resolvedNarc = function()
      return { symbol = "NARC_msgdata_msg", alias = "messages", narcId = 27, fileId = 77, path = "a/0/2/7" }
    end,
    read = function()
      return "archive-bytes"
    end,
    openNarc = function()
      return {
        readMember = function()
          return member
        end,
      }
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
  }
  local bundle, err = FieldMessageCompiler.compile(romFs)
  Assert.isNil(bundle, "expected a failure result")
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_GLYPH_UNMAPPED")
  Assert.equal(assert(err).context.bankId, 542)
  Assert.equal(assert(err).context.messageId, 0)
end

return T
