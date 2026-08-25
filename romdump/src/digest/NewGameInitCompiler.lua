-- Compiles the fresh-game standard-init event initializer from the decoded
-- source `_std_init` standard script (pret/pokeheartgold
-- files/fielddata/script/scr_seq/scr_seq_0149.s): every `SetFlag` becomes a
-- `set_flag` event operation resolved through the project-owned flag symbol
-- table, `LotoIDSet` is recorded as the one recognized non-field-state
-- startup side effect, and any other side-effecting source command fails the
-- build instead of being silently dropped or lowered to a noop. `compile` is
-- the pure semantic step (decoded instructions in, artifact out, raises on
-- drift); `compileFromRom` extracts those instructions from a real dump and
-- wraps the artifact for cache publication. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local NewGameInitCache = require("libs.assets.src.NewGameInitCache")
local Hashing = require("romdump.src.digest.Hashing")

local NewGameInitCompiler = {}

NewGameInitCompiler.ERROR = {
  UNSUPPORTED_SIDE_EFFECT = "NEW_GAME_INIT_UNSUPPORTED_SIDE_EFFECT",
  UNKNOWN_FLAG_SYMBOL = "NEW_GAME_INIT_UNKNOWN_FLAG_SYMBOL",
  SOURCE_INVALID = "NEW_GAME_INIT_SOURCE_INVALID",
}

-- Compiles decoded standard-init instructions into a validated artifact.
-- `input`: { versionId, standardScriptMember, instructions, symbolTable,
-- sourceSha1? }, where `instructions` is `{ { mnemonic, operands }, ... }`
-- (operand values already resolved to symbolic flag names by the decoder).
-- Raises a structured error on any unrecognized or misresolved command
-- instead of returning a partial artifact.
---@param input table
---@return table artifact
function NewGameInitCompiler.compile(input)
  assert(type(input) == "table", "compile requires an input table")
  assert(type(input.versionId) == "string", "compile requires a versionId")
  assert(type(input.standardScriptMember) == "number", "compile requires the standard script member id")
  assert(type(input.instructions) == "table", "compile requires decoded instructions")
  assert(type(input.symbolTable) == "table", "compile requires the flag symbol table")

  local eventOperations = {}
  local nonFieldEffects = {}
  local terminated = false

  for index, instruction in ipairs(input.instructions) do
    if terminated then
      Errors.raise(
        NewGameInitCompiler.ERROR.SOURCE_INVALID,
        "standard init script has instructions after End",
        { index = index }
      )
    end
    local mnemonic = instruction.mnemonic
    if mnemonic == "SetFlag" then
      local symbol = instruction.operands[1]
      local id = input.symbolTable[symbol]
      if id == nil then
        Errors.raise(
          NewGameInitCompiler.ERROR.UNKNOWN_FLAG_SYMBOL,
          "unknown startup flag symbol " .. tostring(symbol),
          { symbol = symbol, index = index }
        )
      end
      eventOperations[#eventOperations + 1] = { op = "set_flag", id = id, symbol = symbol }
    elseif mnemonic == "LotoIDSet" then
      nonFieldEffects[#nonFieldEffects + 1] = "LotoIDSet"
    elseif mnemonic == "End" then
      terminated = true
    else
      Errors.raise(
        NewGameInitCompiler.ERROR.UNSUPPORTED_SIDE_EFFECT,
        "unsupported startup side-effecting command " .. tostring(mnemonic),
        { mnemonic = mnemonic, index = index }
      )
    end
  end
  if not terminated then
    Errors.raise(NewGameInitCompiler.ERROR.SOURCE_INVALID, "standard init script must terminate with End", {})
  end

  local artifact = {
    schema = NewGameInitCache.SCHEMA,
    versionId = input.versionId,
    eventOperations = eventOperations,
    nonFieldEffects = nonFieldEffects,
    sourceDependency = {
      standardScriptMember = input.standardScriptMember,
      sha1 = input.sourceSha1 or "",
    },
  }
  local ok, err = NewGameInitCache.validate(artifact)
  if not ok then
    Errors.raise(NewGameInitCompiler.ERROR.SOURCE_INVALID, "compiled startup artifact is invalid", {
      cause = err and err.message or tostring(err),
    })
  end
  return artifact
end

-- Finds the standard-init script's member id through the pinned standard-
-- script catalog rather than a hardcoded literal, so a source renumbering
-- would move with the catalog instead of silently drifting.
local function standardInitMember(stdCatalog)
  for _, group in ipairs(stdCatalog.groups) do
    if stdCatalog.namesById[group.threshold] == "init" then
      return group.member
    end
  end
  error("standard-script catalog has no 'init' group")
end

-- Extracts the standard-init script's decoded instructions from a real ROM
-- dump, compiles them, and wraps the artifact with the marker the cache
-- writer publishes under.
---@param romFs RomFs
---@param sha1hex? fun(bytes: string): string
---@param hashLua? fun(value: any): string
---@return table|nil bundle, Errors.Error? err
function NewGameInitCompiler.compileFromRom(romFs, sha1hex, hashLua)
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local ok, result = pcall(function()
    assert(
      romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc,
      "compileFromRom requires a RomFs-shaped object"
    )
    local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
    local ScriptMembers = require("romdump.src.reference.hgss.script_members")
    local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

    local archiveInfo = assert(romFs:resolvedNarc("field_scripts"), "field_scripts NARC is unavailable")
    local archive = assert(romFs:openNarc("field_scripts"))
    local sourcePath = "romfs/" .. archiveInfo.path
    local catalog = { flags = require("romdump.src.reference.hgss.flags").byId }
    local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, sourcePath, catalog)

    local stdCatalog = SourceCatalog.catalog()
    local member = standardInitMember(stdCatalog)
    local memberIr = assert(memberIrs[member], "standard init script member is not decodable")
    local script = assert(memberIr.scripts[0], "standard init script has no script index 0")

    -- The catalog names every opcode "ScrCmd_<Name>" (romdump/src/reference/
    -- hgss/script_commands.lua); `compile` works on the bare mnemonic so a
    -- decoded ScrCmd_SetFlag and a hand-written test fixture's "SetFlag"
    -- classify identically.
    local instructions = {}
    for _, ins in ipairs(script.instructions) do
      local operands = {}
      for operandIndex, operand in ipairs(ins.operands) do
        operands[operandIndex] = operand.raw
      end
      instructions[#instructions + 1] = { mnemonic = ins.name:gsub("^ScrCmd_", ""), operands = operands }
    end

    local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
    local memberBytes = assert(archive:readMember(member))
    local artifact = NewGameInitCompiler.compile({
      versionId = romFs:version(),
      standardScriptMember = member,
      instructions = instructions,
      symbolTable = FieldScriptSymbols.flagsByName,
      sourceSha1 = sha1hex(memberBytes),
    })

    local depHash = hashLua(artifact)
    local romSha1 = romFs:metadata().sha1
    local marker = NewGameInitCache.marker(romSha1, depHash)
    return { artifact = artifact, marker = marker, romSha1 = romSha1, depHash = depHash }
  end)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

return NewGameInitCompiler
