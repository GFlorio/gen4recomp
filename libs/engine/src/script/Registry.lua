-- Script resource registry : owns the vanilla base
-- definitions (generated transcripts plus handwritten replacements) and every
-- mod contribution. Contributions are appended in registration order with an
-- explicit priority, owner, and mod load order; the composition layer (not
-- this module) folds them into the effective chain. A `remove` contribution is
-- an explicit tombstone that suppresses the base and lower-priority
-- definitions. The registry also stamps the deterministic fingerprint used by
-- save validation . Pure domain module: no love dependency.

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
local Registry = {}
Registry.__index = Registry

-- Vanilla base layers :
-- the checked-in `data/scripts/overrides` layer is a compatibility layer
-- above the generated transcript but below handwritten replacements;
-- handwritten content takes priority over everything else. The effective
-- base selection happens here so the composition layer only ever sees one
-- base definition.
local BASE_LAYERS = { generated = 1, override = 2, handwritten = 3 }

-- Accepted contribution operations. `replace` is the registry-level alias of
-- `override` ; the stored operation name is `override`.
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

---@return Registry
function Registry.new()
  return setmetatable({
    _bases = {},
    _contributions = {},
    _registrationIndex = 0,
    _version = 0,
    _fingerprintCache = nil,
  }, Registry)
end

-- A script is already defined when any base layer or contribution exists for
-- the id, so `register` cannot silently collide .
---@param id string
---@return boolean
function Registry:has(id)
  return self:_hasBase(id) or (self._contributions[id] ~= nil and #self._contributions[id] > 0)
end

function Registry:_hasBase(id)
  return self._bases[id] ~= nil and next(self._bases[id]) ~= nil
end

-- Install a vanilla base definition. `layer` is "generated", "override", or
-- "handwritten"; handwritten wins, then override, then generated (spec
-- . Installing the same layer twice is
-- a hard duplicate error.
---@param id string
---@param script table
---@param layer string
function Registry:installBase(id, script, layer)
  assert(type(id) == "string" and id ~= "", "script id required")
  assert(type(script) == "table", "base script must be a table")
  assert(BASE_LAYERS[layer] ~= nil, "base layer must be generated, handwritten, or override")
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
  layers[layer] = script
  self._version = self._version + 1
  return script
end

-- The effective base resource: handwritten over override over generated,
-- ignoring mod contributions (the composition layer applies those).
---@param id string
---@return table?
function Registry:base(id)
  local layers = self._bases[id]
  if not layers then
    return nil
  end
  return layers.handwritten or layers.override or layers.generated or nil
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
-- definitions .
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
-- replace/remove contribution, or nil when only before/after/wrap/register
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
-- contribution defines it (mirrors the registry-level `get` of .
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

-- Deterministic registry fingerprint over every base and contribution (spec
-- : ordering, owners, priorities, operations, resource ids, and
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
  for _, id in ipairs(self:ids()) do
    local entry = { id = id, bases = {} }
    for layer in pairs(self._bases[id] or {}) do
      local script = self._bases[id][layer]
      entry.bases[#entry.bases + 1] = {
        layer = layer,
        scriptId = script.id,
        scriptHash = Sha256.hex(LuaWriter.encode(script)),
      }
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
