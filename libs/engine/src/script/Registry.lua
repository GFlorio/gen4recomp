-- Script resource registry : owns the vanilla base
-- definitions (generated transcripts plus overrides) and every mod
-- contribution. Contributions are appended in registration order with an
-- explicit priority, owner, and mod load order; the composition layer (not
-- this module) folds them into the effective chain. A `remove` contribution is
-- an explicit tombstone that suppresses the base and lower-priority
-- definitions. The registry also stamps the deterministic fingerprint used by
-- save validation. Base layers may be installed as deferred placeholders
-- (installBaseDeferred) that decode through an injected resource loader on
-- first access, so a boot never needs to decode the whole generated corpus;
-- the warm-up pass can stash per-resource fingerprint hashes
-- (cacheScriptHash) that fingerprint() consumes without decoding. Pure domain
-- module: no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local Sha256 = require("libs.engine.src.script.Sha256")

---@class Registry
---@field private _bases table<string, table<string, any>> id -> layer -> script
---@field private _contributions table<string, table[]> id -> ordered contribution records
---@field private _registrationIndex integer
---@field private _version integer
---@field private _fingerprintCache table|nil { version: integer, value: string }
---@field private _hashCache table|nil { version: integer, values: table<string, table<string, string>> }
---@field private _loadResource fun(id: string, layer: string): table|nil, any?|nil
local Registry = {}
Registry.__index = Registry

-- Sentinel for a base layer whose resource is not decoded yet.
local PENDING = {}

-- Vanilla base layers : the checked-in `data/scripts/overrides` layer
-- (every script named by the override manifest) sits above the generated
-- transcript. The effective base selection happens here so the composition
-- layer only ever sees one base definition.
local BASE_LAYERS = { generated = 1, override = 2 }

-- Accepted contribution operations.
local OPS = {
  register = true,
  override = true,
  before = true,
  after = true,
  wrap = true,
  remove = true,
}

local VANILLA_OWNER = { kind = "vanilla", id = "base", api = 1 }

-- Normalize a contribution owner : mods pass
-- `{ modId, api }`; engine-owned contributions pass `{ kind, id, api }`.
---@param owner any
---@return table
local function normalizeOwner(owner)
  if type(owner) ~= "table" then
    Errors.raise(ScriptErrors.SCRIPT_SCHEMA_INVALID, "contribution owner must be a table", { owner = owner })
  end
  if owner.modId ~= nil then
    if type(owner.modId) ~= "string" or owner.modId == "" then
      Errors.raise(
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "contribution owner modId must be a non-empty string",
        { modId = owner.modId }
      )
    end
    return { kind = "mod", id = owner.modId, api = owner.api or 1 }
  end
  if type(owner.kind) ~= "string" or type(owner.id) ~= "string" or owner.id == "" then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "contribution owner must be {modId, api} or {kind, id, api}",
      { owner = owner }
    )
  end
  return { kind = owner.kind, id = owner.id, api = owner.api or 1 }
end

---@param opts table|nil { loadResource: fun(id: string, layer: string): table|nil, any?|nil }
---@return Registry
function Registry.new(opts)
  opts = opts or {}
  return setmetatable({
    _bases = {},
    _contributions = {},
    _registrationIndex = 0,
    _version = 0,
    _fingerprintCache = nil,
    _hashCache = nil,
    _loadResource = opts.loadResource,
  }, Registry)
end

-- A script is already defined when any base layer or contribution exists for
-- the id, so `register` cannot silently collide.
---@param id string
---@return boolean
function Registry:has(id)
  return self:_hasBase(id) or (self._contributions[id] ~= nil and #self._contributions[id] > 0)
end

function Registry:_hasBase(id)
  return self._bases[id] ~= nil and next(self._bases[id]) ~= nil
end

-- Install a vanilla base definition. `layer` is "generated" or "override";
-- override wins over the generated transcript. Installing the same layer
-- twice is a hard duplicate error.
---@param id string
---@param script table
---@param layer string
function Registry:installBase(id, script, layer)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, script)
  return script
end

-- Record a base layer whose resource is not decoded yet; `base` resolves it
-- through the registry's resource loader on first access. Same duplicate
-- rules as installBase.
---@param id string
---@param layer string
function Registry:installBaseDeferred(id, layer)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  self:_installLayer(id, layer, PENDING)
end

function Registry:_installLayer(id, layer, value)
  local layers = self._bases[id]
  if layers == nil then
    layers = {}
    self._bases[id] = layers
  end
  if layers[layer] ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_DUPLICATE_ID,
      "duplicate base definition for " .. id,
      { scriptId = id, layer = layer, owner = VANILLA_OWNER }
    )
  end
  layers[layer] = value
  self._version = self._version + 1
end

-- Decode a pending layer through the resource loader and memoize it in the
-- slot; the loader is wired at construction, so its absence is a programming
-- fault, and a loader failure is a hard load error.
---@param id string
---@param layer string
---@return table
function Registry:_load(id, layer)
  local loader = assert(self._loadResource, "registry has no resource loader for deferred base " .. id)
  local resource, err = loader(id, layer)
  if resource == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_LOAD_FAILED,
      "deferred base is unavailable: " .. id .. " (" .. tostring(err and err.message or "?") .. ")",
      { scriptId = id, layer = layer, cause = err and err.context or nil }
    )
  end
  ---@cast resource table
  self._bases[id][layer] = resource
  return resource
end

-- The effective base resource: override over generated, ignoring mod
-- contributions (the composition layer applies those). A deferred layer
-- decodes on first access and is memoized.
---@param id string
---@return table?
function Registry:base(id)
  local layers = self._bases[id]
  if not layers then
    return nil
  end
  local layer = layers.override and "override" or layers.generated and "generated"
  if not layer then
    return nil
  end
  local script = layers[layer]
  if script == PENDING then
    script = self:_load(id, layer)
  end
  return script
end

-- Append one contribution. The `owner` may be a mod `{modId, api}` or an
-- engine `{kind, id, api}`; `loadOrder` is the resolved mod load order
-- (ascending) and `priority` orders contributions within one target.
---@param id string
---@param operation string
---@param resource table|nil
---@param owner any
---@param opts table|nil
---@return table contribution record
function Registry:_append(id, operation, resource, owner, opts)
  opts = opts or {}
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(OPS[operation] ~= nil, "unknown registry operation " .. tostring(operation))
  assert(operation == "remove" or type(resource) == "table", "contribution resource must be a table")
  local normalized = normalizeOwner(owner)
  local priority = opts.priority or 0
  if type(priority) ~= "number" then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "contribution priority must be a number",
      { scriptId = id, owner = normalized }
    )
  end
  local loadOrder = opts.loadOrder or 0
  if type(loadOrder) ~= "number" then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "contribution loadOrder must be a number",
      { scriptId = id, owner = normalized }
    )
  end
  self._registrationIndex = self._registrationIndex + 1
  local record = {
    operation = operation,
    target = id,
    resource = resource,
    priority = priority,
    owner = normalized,
    loadOrder = loadOrder,
    registrationIndex = self._registrationIndex,
  }
  local list = self._contributions[id]
  if list == nil then
    list = {}
    self._contributions[id] = list
  end
  list[#list + 1] = record
  self._version = self._version + 1
  return record
end

-- Register a brand-new script id. Collides with a base or an existing
-- registration: use `override` to replace.
---@param id string
---@param script table
---@param owner any
---@param opts table|nil
---@return table
function Registry:register(id, script, owner, opts)
  if self:has(id) then
    Errors.raise(
      ScriptErrors.SCRIPT_DUPLICATE_ID,
      "script id is already defined: " .. id,
      { scriptId = id, owner = normalizeOwner(owner) }
    )
  end
  return self:_append(id, "register", script, owner, opts)
end

---@param id string
---@param script table
---@param owner any
---@param opts table|nil
---@return table
function Registry:override(id, script, owner, opts)
  return self:_append(id, "override", script, owner, opts)
end

---@param id string
---@param script table
---@param owner any
---@param opts table|nil
---@return table
function Registry:before(id, script, owner, opts)
  return self:_append(id, "before", script, owner, opts)
end

---@param id string
---@param script table
---@param owner any
---@param opts table|nil
---@return table
function Registry:after(id, script, owner, opts)
  return self:_append(id, "after", script, owner, opts)
end

---@param id string
---@param script table
---@param owner any
---@param opts table|nil
---@return table
function Registry:wrap(id, script, owner, opts)
  return self:_append(id, "wrap", script, owner, opts)
end

-- Explicit tombstone: suppresses the vanilla base and lower-priority
-- definitions.
---@param id string
---@param owner any
---@param opts table|nil
---@return table
function Registry:remove(id, owner, opts)
  return self:_append(id, "remove", nil --[[@as table]], owner, opts)
end

-- Deterministically sorted contribution list for one id :
-- priority descending, then mod load order ascending, then registration index
-- ascending.
---@param id string
---@return table[]
function Registry:contributions(id)
  local list = {}
  for _, record in ipairs(self._contributions[id] or {}) do
    list[#list + 1] = record
  end
  table.sort(list, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    if a.loadOrder ~= b.loadOrder then
      return a.loadOrder < b.loadOrder
    end
    return a.registrationIndex < b.registrationIndex
  end)
  return list
end

-- The first base-definition contender at the highest priority: an override/
-- remove contribution, or nil when only before/after/wrap/register
-- contributions exist. Same-priority conflicts are the composition layer's
-- call; this helper returns the raw contenders.
---@param id string
---@return table[] contenders in sorted order
function Registry:definitionContenders(id)
  local out = {}
  for _, record in ipairs(self:contributions(id)) do
    if record.operation == "override" or record.operation == "remove" or record.operation == "register" then
      out[#out + 1] = record
    end
  end
  return out
end

-- The winning definition record (first contender, possibly replaced by a
-- same-priority, same-owner later one), or nil.
---@param id string
---@return table?
function Registry:_definition(id)
  local contenders = self:definitionContenders(id)
  if #contenders == 0 then
    return nil
  end
  local winner = contenders[1]
  for i = 2, #contenders do
    if
      contenders[i].priority == winner.priority
      and contenders[i].owner.id == winner.owner.id
      and contenders[i].owner.kind == winner.owner.kind
    then
      winner = contenders[i]
    else
      break
    end
  end
  return winner
end

-- The raw contributed resource for inspection, or the resolved base when no
-- contribution defines it (mirrors the registry-level `get`).
---@param id string
---@return table|nil
function Registry:get(id)
  local definition = self:_definition(id)
  if definition ~= nil then
    if definition.operation == "remove" then
      return nil
    end
    return definition.resource
  end
  return self:base(id)
end

-- All ids with any definition (bases or contributions), sorted and
-- deduplicated: an id having both a base and a contribution appears once.
---@return string[]
function Registry:ids()
  local seen = {}
  for id in pairs(self._bases) do
    seen[id] = true
  end
  for id in pairs(self._contributions) do
    if #self._contributions[id] > 0 then
      seen[id] = true
    end
  end
  local out = {}
  for id in pairs(seen) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

-- A monotonic mutation counter; the composition cache keys on it.
---@return integer
function Registry:version()
  return self._version
end

-- Preload the fingerprint memo from a validated keyed snapshot: the key
-- proves the registry content is what the digest was computed from. Valid
-- only while the registry is unmutated; any later install bumps `_version`
-- and the memo is recomputed from live content.
---@param value string
function Registry:restoreFingerprint(value)
  assert(type(value) == "string" and value ~= "", "restored fingerprint must be a non-empty string")
  self._fingerprintCache = { version = self._version, value = value }
end

-- Stash one base layer's fingerprint hash so fingerprint() can assemble the
-- digest without decoding that resource. Keyed on the mutation version: any
-- later install invalidates the stash and fingerprint() recomputes live.
-- The hash must be exactly what fingerprint() would compute
-- (Sha256.hex(LuaWriter.encode(resource))).
---@param id string
---@param layer string
---@param hash string
function Registry:cacheScriptHash(id, layer, hash)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated or override")
  assert(type(hash) == "string" and #hash == 64, "script hash must be a 64-character hex digest")
  local cache = self._hashCache
  if cache == nil or cache.version ~= self._version then
    cache = { version = self._version, values = {} }
    self._hashCache = cache
  end
  local byLayer = cache.values[id]
  if byLayer == nil then
    byLayer = {}
    cache.values[id] = byLayer
  end
  byLayer[layer] = hash
end

-- Deterministic registry fingerprint over every base and contribution:
-- ordering, owners, priorities, operations, resource ids, and
-- a content hash of each resource. The fingerprint therefore changes when a
-- script's executable content changes even when its id does not. Saves
-- record it; load rejects a mismatch. The registry is immutable during
-- gameplay, so the digest is memoized on the mutation version; the game saves
-- after every warp and on quit, and re-hashing the full corpus each time made
-- the autosave stall.
---@return string
function Registry:fingerprint()
  local cached = self._fingerprintCache
  if cached ~= nil and cached.version == self._version then
    return cached.value
  end
  local projection = {}
  local hashCache = self._hashCache
  local cachedValues
  if hashCache ~= nil and hashCache.version == self._version then
    cachedValues = hashCache.values
  end
  for _, id in ipairs(self:ids()) do
    local entry = { id = id, bases = {} }
    local byLayer = cachedValues and cachedValues[id] or nil
    for layer in pairs(self._bases[id] or {}) do
      local cachedHash = byLayer and byLayer[layer] or nil
      if cachedHash ~= nil then
        -- A stashed hash implies the resource was already decoded with its
        -- id checked at load time, so the layer id equals the script id.
        entry.bases[#entry.bases + 1] = { layer = layer, scriptId = id, scriptHash = cachedHash }
      else
        local script = self._bases[id][layer]
        if script == PENDING then
          script = self:_load(id, layer)
        end
        entry.bases[#entry.bases + 1] = {
          layer = layer,
          scriptId = script.id,
          scriptHash = Sha256.hex(LuaWriter.encode(script)),
        }
      end
    end
    table.sort(entry.bases, function(a, b)
      return a.layer < b.layer
    end)
    local contributions = {}
    for _, record in ipairs(self:contributions(id)) do
      contributions[#contributions + 1] = {
        operation = record.operation,
        priority = record.priority,
        owner = record.owner,
        loadOrder = record.loadOrder,
        registrationIndex = record.registrationIndex,
        scriptId = record.resource and record.resource.id or nil,
        scriptHash = record.resource and Sha256.hex(LuaWriter.encode(record.resource)) or nil,
      }
    end
    entry.contributions = contributions
    projection[#projection + 1] = entry
  end
  local value = Sha256.hex(LuaWriter.encode(projection))
  self._fingerprintCache = { version = self._version, value = value }
  return value
end

return Registry
