-- Compiles the selected HGSS message banks (romdump/src/config/FieldMessages.lua)
-- into tokenized, lossless bank artifacts. Each bank member is validated and
-- decrypted by FieldMessageBank (src/msgdata.c Decrypt1/Decrypt2) and then
-- tokenized by FieldMessageTokenizer. Identity and bank selection come from
-- the frozen map catalog and the selected-set manifest only.

local Errors = require("libs.errors.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local FieldMessageBank = require("romdump.src.digest.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.FieldMessageText")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local charmap = require("romdump.src.reference.hgss.charmap")
local manifest = require("romdump.src.config.FieldMessages")

---@class FieldMessageCompiler.Bundle
---@field marker string
---@field index { schema: string, version: string, bankIds: integer[] }
---@field banks table<integer, table>
---@field dependencies table

local FieldMessageCompiler = {}

FieldMessageCompiler.COMPILER_VERSION = "field-message-compiler-v2"
FieldMessageCompiler.TOKENIZER_VERSION = "g4-field-message-tokenizer-v1"
FieldMessageCompiler.CHARMAP_VERSION = "hgss-charmap-v1:"
  .. charmap.source.commit
  .. ":"
  .. charmap.source.inputs[1].sha256

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function loadSource(romFs, sha1hex)
  local archiveInfo = romFs:resolvedNarc("messages")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "messages NARC is unavailable", { name = "messages" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("messages"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

local function compileBank(romFs, source, bankId, sha1hex)
  local memberBytes = must(source.archive:readMember(bankId))
  local bank = must(FieldMessageBank.decode(memberBytes, {
    label = "msgdata-member-" .. bankId,
    messageId = bankId,
  }))
  local memberSha1 = sha1hex(memberBytes)

  local messages = {}
  for index = 0, bank.messageCount - 1 do
    local message = bank.messages[index + 1]
    local tokens, tokenizeErr = FieldMessageTokenizer.tokenize(message.raw, charmap, {
      bankId = bankId,
      messageId = index,
    })
    if not tokens then
      tokenizeErr = assert(tokenizeErr)
      tokenizeErr.context = tokenizeErr.context or {}
      tokenizeErr.context.bankId = bankId
      tokenizeErr.context.messageId = index
      error(tokenizeErr)
    end
    messages[index] = {
      id = index,
      -- Modder-facing display text (GMM-style markers for controls); the
      -- token stream stays beside it as the lossless rendering source.
      text = FieldMessageText.tokensToText(tokens),
      raw = message.raw,
      tokens = tokens,
    }
  end

  return {
    schema = FieldMessageCache.SCHEMA,
    bankId = bankId,
    messageCount = bank.messageCount,
    key = bank.key,
    source = {
      narc = source.archiveInfo.symbol,
      memberId = bankId,
      memberSha1 = memberSha1,
    },
    messages = messages,
  }
end

local function _compile(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local source = loadSource(romFs, sha1hex)

  local banks = {}
  for _, bankId in ipairs(manifest.banks) do
    banks[bankId] = compileBank(romFs, source, bankId, sha1hex)
  end

  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = romFs:version(),
    bankIds = manifest.banks,
  }

  local dependencies = {
    cacheFormat = FieldMessageCache.FORMAT,
    compilerVersion = FieldMessageCompiler.COMPILER_VERSION,
    tokenizerVersion = FieldMessageCompiler.TOKENIZER_VERSION,
    charmapVersion = FieldMessageCompiler.CHARMAP_VERSION,
    manifestSchema = manifest.schema,
    versionRomSha1 = romFs:metadata().sha1,
    messageNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
  }
  for _, bankId in ipairs(manifest.banks) do
    dependencies["bank" .. bankId .. "MemberSha1"] = banks[bankId].source.memberSha1
  end

  local marker = FieldMessageCache.marker(romFs:metadata().sha1, hashLua(dependencies))
  return {
    marker = marker,
    index = index,
    banks = banks,
    dependencies = dependencies,
  }
end

---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string|nil
---@param hashLua? fun(value: any): string|nil
---@return FieldMessageCompiler.Bundle?
---@return Errors.Error?
function FieldMessageCompiler.compile(romFs, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, sha1hex, hashLua)
  if ok then
    return result, nil
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return FieldMessageCompiler
