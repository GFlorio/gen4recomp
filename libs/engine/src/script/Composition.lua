-- Effective script composition : folds the
-- registry's contributions for one public script id into a deterministic
-- executable chain. Execution order: `before` high
-- priority to low, `wrap` high outermost, the resolved base or replacement,
-- then `after` low priority to high. Each contribution compiles to its own
-- graph; `before`/`after`/`wrap` compile as wrappers (`allowNext`).
-- Same-priority replacements from different
-- owners are a hard load error; a winning tombstone suppresses
-- the base and every lower-priority contribution. The
-- effective result is cached per id and keyed on the registry mutation
-- version. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.engine.src.script.Sha256")
local Compiler = require("libs.engine.src.script.Compiler")

---@class Composition
---@field private _registry Registry
---@field private _compile fun(script: table, opts: table): table
---@field private _cache table<string, { version: integer, result: any }>
local Composition = {}
Composition.__index = Composition

local VANILLA_OWNER = { kind = "vanilla", id = "base", api = 1 }

-- Compile a contribution resource, attributing compile failures to the
-- contribution's owner and the target id.
---@param compile fun(script: table, opts: table): table
---@param resource table
---@param allowNext boolean
---@param target string
---@param owner table
---@return table graph
local function compileContribution(compile, resource, allowNext, target, owner)
  local graph, err = compile(resource, { allowNext = allowNext })
  if not graph then
    Errors.raise(
      err and err.code or ScriptErrors.SCRIPT_SCHEMA_INVALID,
      tostring(err and err.message or "contribution failed to compile"),
      { scriptId = target, target = target, owner = owner, cause = err }
    )
  end
  return graph
end

---@param registry Registry
---@param opts table|nil
---@return Composition
function Composition.new(registry, opts)
  opts = opts or {}
  return setmetatable({
    _registry = registry,
    _compile = opts.compile or Compiler.compile,
    _cache = {},
  }, Composition)
end

-- The winning base-definition record for one id, raising on the replacement
-- conflict: two replacements from different owners at the same winning
-- priority. The winner is the first definition contender at the highest
-- priority; a later same-priority, same-owner contender replaces it.
---@param id string
---@return table|nil
function Composition:_winningDefinition(id)
  local winner = nil
  for _, record in ipairs(self._registry:definitionContenders(id)) do
    if winner == nil then
      winner = record
    elseif record.priority == winner.priority then
      if record.owner.kind ~= winner.owner.kind or record.owner.id ~= winner.owner.id then
        Errors.raise(
          ScriptErrors.SCRIPT_REPLACE_CONFLICT,
          "conflicting replacements for " .. id .. " at priority " .. record.priority,
          { scriptId = id, priority = record.priority, firstOwner = winner.owner, secondOwner = record.owner }
        )
      end
      winner = record
    end
  end
  return winner
end

-- Build the executable chain for one id. Returns nil when the id has no
-- definition at all (no base, no contributions). A winning remove tombstone
-- suppresses the base and every lower-priority contribution: before/wrap/
-- after records below the tombstone's priority are dropped.
---@param id string
---@return table|nil chain
function Composition:_resolve(id)
  local contributions = self._registry:contributions(id)
  local winner = self:_winningDefinition(id)
  local tombstonePriority = nil
  if winner ~= nil and winner.operation == "remove" then
    tombstonePriority = winner.priority
  end
  local befores, wraps, afters = {}, {}, {}
  for _, record in ipairs(contributions) do
    local op = record.operation
    if tombstonePriority ~= nil and record.priority < tombstonePriority then
      -- Suppressed by the winning tombstone.
    elseif op == "before" then
      befores[#befores + 1] = record
    elseif op == "wrap" then
      wraps[#wraps + 1] = record
    elseif op == "after" then
      afters[#afters + 1] = record
    end
  end
  local baseResource
  if winner ~= nil then
    baseResource = winner.operation == "remove" and nil or winner.resource
  else
    baseResource = self._registry:base(id)
  end

  if baseResource == nil and #befores == 0 and #wraps == 0 and #afters == 0 then
    return nil
  end

  local entries = {}
  local function push(resource, operation, owner)
    local allowNext = operation ~= "base"
      and operation ~= "register"
      and operation ~= "override"
      and operation ~= "remove"
    local graph = compileContribution(self._compile, resource, allowNext, id, owner)
    entries[#entries + 1] = {
      operation = operation,
      owner = owner,
      script = resource,
      scriptId = resource.id,
      graphRevision = graph.revision,
      graph = graph,
    }
  end

  for _, record in ipairs(befores) do
    push(record.resource, "before", record.owner)
  end
  for _, record in ipairs(wraps) do
    push(record.resource, "wrap", record.owner)
  end
  if baseResource ~= nil then
    local operation = winner and winner.operation or "base"
    local owner = winner and winner.owner or VANILLA_OWNER
    push(baseResource, operation, owner)
  end
  -- afters run lowest priority first : the contributions are
  -- sorted priority-descending, so walk them in reverse.
  for i = #afters, 1, -1 do
    push(afters[i].resource, "after", afters[i].owner)
  end

  local projection = { scriptId = id }
  for _, entry in ipairs(entries) do
    projection[#projection + 1] = {
      operation = entry.operation,
      owner = entry.owner,
      scriptId = entry.scriptId,
      revision = entry.graphRevision,
    }
  end

  return {
    scriptId = id,
    revision = Sha256.hex(LuaWriter.encode(projection)),
    entries = entries,
  }
end

-- The effective composed chain for one public script id, or nil when the id
-- is unknown. Raises on load-time composition faults (replacement conflict,
-- uncompilable contribution). Cached until the registry mutates.
---@param id string
---@return table|nil
function Composition:effective(id)
  local cached = self._cache[id]
  local version = self._registry:version()
  if cached ~= nil and cached.version == version then
    return cached.result
  end
  local result = self:_resolve(id)
  self._cache[id] = { version = version, result = result }
  return result
end

return Composition
