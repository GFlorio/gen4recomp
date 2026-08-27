-- Compiles normalized field events into the generated script binding
-- manifest. Source script indices are resolved here, at the ROM boundary,
-- through ScriptCompiler's public-ID policy and the checked-in override
-- target data; runtime consumers receive only semantic event identities.

local Errors = require("libs.errors.src.Errors")
local ScriptCache = require("libs.assets.src.ScriptCache")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local OverrideTargets = require("romdump.src.reference.hgss.script_override_targets")

local BindingCompiler = {}

local function sourcePairs(scriptBundle)
  assert(type(scriptBundle) == "table" and type(scriptBundle.resources) == "table", "script bundle resources required")
  local pairs = {}
  for _, resource in ipairs(scriptBundle.resources) do
    assert(type(resource) == "table", "script resource metadata required")
    assert(type(resource.member) == "number" and type(resource.scriptIndex) == "number", "script source pair required")
    local member = pairs[resource.member]
    if member == nil then
      member = {}
      pairs[resource.member] = member
    end
    member[resource.scriptIndex] = true
  end
  return pairs
end

local function sourceFailure(mapId, kind, scriptBankId, event, scriptIndex)
  Errors.raise(
    "SCRIPT_BINDING_SOURCE_MISSING",
    "field event references a script absent from the compiled script corpus",
    {
      mapId = mapId,
      eventKind = kind,
      eventIndex = event.index,
      objectEventId = event.objectEventId,
      scriptBankId = scriptBankId,
      rawScriptId = event.scriptId,
      scriptIndex = scriptIndex,
    }
  )
end

local function targetFor(mapId, kind, scriptBankId, event, source, stdCatalog)
  local rawScriptId = event.scriptId
  assert(type(rawScriptId) == "number" and rawScriptId > 0, "bindable event requires a positive script id")
  assert(rawScriptId % 1 == 0, "bindable event script id must be an integer")
  local scriptIndex = (rawScriptId - 1) --[[@as integer]]
  local member = source[scriptBankId]
  if member == nil or not member[scriptIndex] then
    sourceFailure(mapId, kind, scriptBankId, event, scriptIndex)
  end
  local override = OverrideTargets[scriptBankId]
  override = override and override[scriptIndex] or nil
  if override ~= nil then
    return override.id
  end
  return ScriptCompiler.publicId(scriptBankId, scriptIndex, stdCatalog)
end

local function insertBinding(section, key, target, context)
  if section[key] ~= nil then
    Errors.raise(
      "SCRIPT_BINDING_DUPLICATE",
      "multiple field events claim the same binding identity",
      { mapId = context.mapId, eventKind = context.eventKind, eventIndex = key, objectEventId = context.objectEventId }
    )
  end
  section[key] = target
end

local function compileMap(bundle, source, stdCatalog)
  local mapId = bundle.mapId
  local field = assert(bundle.field)
  local events = assert(field.events)
  local map = { objects = {}, backgrounds = {}, coordinates = {} }

  for _, event in ipairs(assert(events.objects)) do
    if event.scriptId ~= 0 then
      local target = targetFor(mapId, "object", field.scriptBankId, event, source, stdCatalog)
      insertBinding(map.objects, event.objectEventId, target, {
        mapId = mapId,
        eventKind = "object",
        objectEventId = event.objectEventId,
      })
    end
  end
  for _, event in ipairs(assert(events.background)) do
    if event.scriptId ~= 0 and event.hiddenItem ~= true then
      local target = targetFor(mapId, "background", field.scriptBankId, event, source, stdCatalog)
      insertBinding(map.backgrounds, event.index, target, {
        mapId = mapId,
        eventKind = "background",
      })
    end
  end
  for _, event in ipairs(assert(events.coordinates)) do
    if event.scriptId ~= 0 then
      local target = targetFor(mapId, "coordinate", field.scriptBankId, event, source, stdCatalog)
      insertBinding(map.coordinates, event.index, target, {
        mapId = mapId,
        eventKind = "coordinate",
      })
    end
  end
  return map
end

---@param fieldBundles table[] normalized field-map compiler bundles
---@param scriptBundle table compiled script resources with source metadata
---@return table generated binding manifest
function BindingCompiler.compile(fieldBundles, scriptBundle)
  assert(type(fieldBundles) == "table", "field bundles required")
  local source = sourcePairs(scriptBundle)
  local stdCatalog = SourceCatalog.catalog()
  local maps = {}
  for _, bundle in ipairs(fieldBundles) do
    assert(type(bundle) == "table" and type(bundle.mapId) == "number", "field bundle map id required")
    if maps[bundle.mapId] ~= nil then
      Errors.raise("SCRIPT_BINDING_DUPLICATE_MAP", "field bundles contain a duplicate map", { mapId = bundle.mapId })
    end
    maps[bundle.mapId] = compileMap(bundle, source, stdCatalog)
  end
  return { schema = ScriptCache.BINDINGS_SCHEMA, maps = maps }
end

return BindingCompiler
