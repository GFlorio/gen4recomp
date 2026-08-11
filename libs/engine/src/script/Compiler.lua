-- Compiles a validated gen4 field-script resource into the internal graph
-- that the runtime executes. Node IDs are either the author `key`, a
-- generated `src:<member>:<index>:<offset>[/<op>]`, or a structural
-- `path:steps/3/no/2`. The revision hash covers the serialized graph
-- projection, whose node map is keyed by node ID. Node IDs embed identity:
-- generated `src:` IDs carry metadata.source member/scriptIndex and
-- provenance offsets, `key:` IDs carry the author key. Edits to those
-- fields change the revision for nodes of that kind; only the node `source`
-- payload, warnings, and non-identity metadata are excluded.
-- Load-time structural validation also lives here: label uniqueness/targets,
-- wrapper-only `next`, local call-target resolution, and static nesting.
-- Non-yielding recursion is not rejected at load time; the scheduler's
-- deterministic per-run node budget faults it at runtime instead. The
-- compiler deep-copies authoring tables; compiled graphs share no nested
-- tables with the authoring input. All mutable compilation state (nodes,
-- labels, used ids, warnings, opts) is a context local to each invocation,
-- passed explicitly to the stateful helpers, so calls are reentrant and
-- cannot contaminate one another.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local Schema = require("libs.engine.src.script.Schema")
local Validator = require("libs.engine.src.script.Validator")
local Sha256 = require("libs.engine.src.script.Sha256")
local Graph = require("libs.engine.src.script.Graph")

local Compiler = {}

-- Maximum static if/switch nesting depth.
Compiler.MAX_STATIC_NESTING = 64

-- Ops whose linear continuation is not a `next` edge: branch nodes carry
-- explicit edges, calls carry return frames, and stop/return/next terminate.
local NO_CHAIN_NEXT = {
  ["if"] = true,
  switch = true,
  ["goto"] = true,
  goto_if = true,
  goto_compared = true,
  call = true,
  call_compared = true,
  ["return"] = true,
  stop = true,
  next = true,
}

-- Ops that warn on handwritten (non-generated) scripts
local FALLBACK_OPS = {
  label = true,
  ["goto"] = true,
  goto_if = true,
  goto_compared = true,
  call_compared = true,
  goto_script = true,
}

local ACTOR_SPECIALS_SET = {}
for _, special in ipairs(Schema.ACTOR_SPECIALS) do
  ACTOR_SPECIALS_SET[special] = true
end

-- Deep copy of serializable data (the validator guarantees acyclicity).
---@param value any
---@return any
local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

-- Apply schema field defaults to a normalized table (defaults are copied per
-- table so they are never shared).
---@param t table
---@param spec table
local function applyDefaults(t, spec)
  for name, field in pairs(spec.fields) do
    if field.default ~= nil and t[name] == nil then
      t[name] = deepCopy(field.default)
    end
  end
end

-- Normalization helpers. Each returns a fresh deep-copied table with schema
-- defaults applied and nested references canonicalized (value/text/condition/
-- actor/message forms).

local normalizeByType
local normalizeStep

-- Shared shape for value/text/condition references: copy, apply defaults,
-- normalize nested fields by their schema types.
---@param v table
---@param kindMap table
---@param discriminator string
---@return table
local function normalizeKind(v, kindMap, discriminator)
  local spec = kindMap[v[discriminator]]
  local out = deepCopy(v)
  applyDefaults(out, spec)
  for name, field in pairs(spec.fields) do
    if out[name] ~= nil then
      out[name] = normalizeByType(out[name], field.type)
    end
  end
  return out
end

local function normalizeValue(v)
  return normalizeKind(v, Schema.VALUES, "value")
end
local function normalizeCondition(v)
  return normalizeKind(v, Schema.CONDITIONS, "condition")
end
local function normalizeText(v)
  return normalizeKind(v, Schema.TEXT_VALUES, "text")
end

-- String actor shorthand becomes an actor reference.
---@param v any
---@return table
local function normalizeActor(v)
  if type(v) == "string" then
    if ACTOR_SPECIALS_SET[v] then
      return { ref = "actor", special = v }
    end
    return { ref = "actor", id = v }
  end
  return deepCopy(v)
end

local function normalizeMessage(v)
  if type(v) == "string" then
    return v
  end
  if v.value ~= nil then
    return normalizeValue(v)
  end
  if v.message == "external" then
    local out = deepCopy(v)
    out.bank = normalizeByType(out.bank, "scalar_or_value")
    out.id = normalizeByType(out.id, "scalar_or_value")
    return out
  end
  if v.text == "gendered_message" then
    local out = normalizeText(v)
    out.male = normalizeMessage(out.male)
    out.female = normalizeMessage(out.female)
    return out
  end
  assert(false, "validator must reject unknown message reference forms")
end

local function normalizeSteps(steps)
  local out = {}
  for i = 1, #steps do
    out[i] = normalizeStep(steps[i])
  end
  return out
end

normalizeStep = function(t)
  local spec = assert(Schema.OPERATIONS[t.op], "validator must reject unknown ops")
  local out = deepCopy(t)
  applyDefaults(out, spec)
  for name, field in pairs(spec.fields) do
    if out[name] ~= nil then
      out[name] = normalizeByType(out[name], field.type)
    end
  end
  return out
end

normalizeByType = function(v, ty)
  if v == nil then
    return nil
  end
  if ty == "steps" then
    return normalizeSteps(v)
  elseif ty == "cases" then
    local out = {}
    for k, caseSteps in pairs(v) do
      out[k] = normalizeSteps(caseSteps)
    end
    return out
  elseif ty == "condition" then
    return normalizeCondition(v)
  elseif ty == "condition_list" then
    local out = {}
    for i = 1, #v do
      out[i] = normalizeCondition(v[i])
    end
    return out
  elseif ty == "value" then
    return normalizeValue(v)
  elseif ty == "scalar_or_value" then
    if type(v) == "table" then
      return normalizeValue(v)
    end
    return v
  elseif ty == "id_or_var" then
    if type(v) == "table" then
      return normalizeValue(v)
    end
    return v
  elseif ty == "text_value" then
    return normalizeText(v)
  elseif ty == "message" then
    return normalizeMessage(v)
  elseif ty == "actor" then
    return normalizeActor(v)
  elseif ty == "actor_list" then
    local out = {}
    for i = 1, #v do
      out[i] = normalizeActor(v[i])
    end
    return out
  elseif ty == "movement" then
    local out = {}
    for i = 1, #v do
      local item = deepCopy(v[i])
      applyDefaults(item, Schema.MOVEMENT_ACTIONS[item.action])
      out[i] = item
    end
    return out
  elseif ty == "args" then
    local out = {}
    for k, arg in pairs(v) do
      if type(arg) == "table" then
        if arg.value ~= nil then
          arg = normalizeValue(arg)
        elseif arg.text ~= nil then
          arg = normalizeText(arg)
        else
          arg = normalizeActor(arg)
        end
      end
      out[k] = arg
    end
    return out
  elseif ty == "bindings" then
    local out = {}
    for k, textValue in pairs(v) do
      out[k] = normalizeText(textValue)
    end
    return out
  end
  return deepCopy(v)
end

-- Node ID for a step : author `key`, else generated
-- `src:<member>:<script-index>:<first-offset>[/<op>]`, else structural path.
-- A multi-step lowering (one source instruction expanded into several
-- canonical steps) shares provenance; the second and later steps append a
-- `/n` counter so every node id stays unique.
---@param context table per-call compiler state
---@param step table
---@param path string
---@return string
local function nodeIdFor(context, step, path)
  if step.key ~= nil then
    return "key:" .. step.key
  end
  local provenance = step.provenance
  if provenance ~= nil then
    local metaSource = context.script.metadata and context.script.metadata.source
    local member = metaSource and metaSource.member
    local scriptIndex = metaSource and metaSource.scriptIndex
    if member == nil or scriptIndex == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "step provenance requires script metadata.source member and scriptIndex",
        { scriptId = context.script.id, path = path, op = step.op }
      )
    end
    assert(#provenance.offsets > 0, "provenance must name a source offset")
    local base = string.format("src:%04d:%03d:%04x", member, scriptIndex, provenance.offsets[1])
    local id = base
    if #provenance.offsets > 1 then
      id = base .. "/" .. step.op
    end
    local seen = context.usedNodeIds[id]
    if seen ~= nil then
      context.usedNodeIds[id] = seen + 1
      id = base .. "/" .. step.op .. "/" .. tostring(seen + 1)
    else
      context.usedNodeIds[id] = 1
    end
    return id
  end
  return "path:" .. path
end

local function addWarning(context, message, nodeId)
  context.warnings[#context.warnings + 1] = { message = message, nodeId = nodeId }
end

-- Pre-pass: assign every node ID exactly once, in deterministic tree order
-- (the same order the compile pass emits nodes), so label registration and
-- compilation share one immutable id map. The provenance suffix counter is
-- consumed here and never again: a label is registered and emitted under the
-- very same id. The switch default branch is part of the tree.
---@param context table per-call compiler state
---@param steps table
---@param path string
local function assignNodeIds(context, steps, path)
  for i = 1, #steps do
    local step = steps[i]
    local p = path .. "/" .. tostring(i - 1)
    context.nodeIds[p] = nodeIdFor(context, step, p)
    if step.op == "if" then
      assignNodeIds(context, step.yes, p .. "/yes")
      assignNodeIds(context, step.no, p .. "/no")
    elseif step.op == "switch" then
      local keys = {}
      for k in pairs(step.cases) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        assignNodeIds(context, step.cases[k], p .. "/" .. tostring(k))
      end
      assignNodeIds(context, step.default, p .. "/default")
    end
  end
end

-- Pre-pass: register every label name with its precomputed node ID.
---@param context table per-call compiler state
---@param steps table
---@param path string
local function prewalk(context, steps, path)
  for i = 1, #steps do
    local step = steps[i]
    local p = path .. "/" .. tostring(i - 1)
    if step.op == "label" then
      local name = step.name
      if context.labelNodeIds[name] ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "duplicate label name",
          { scriptId = context.script.id, path = p, label = name }
        )
      end
      context.labelNodeIds[name] = assert(context.nodeIds[p], "label node id was not precomputed")
    end
    if step.op == "if" then
      prewalk(context, step.yes, p .. "/yes")
      prewalk(context, step.no, p .. "/no")
    elseif step.op == "switch" then
      local keys = {}
      for k in pairs(step.cases) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        prewalk(context, step.cases[k], p .. "/" .. tostring(k))
      end
      prewalk(context, step.default, p .. "/default")
    end
  end
end

-- Compile one step into a node. `cont` is the node ID the step's control flow
-- continues at (nil at the script end). Returns the node ID.
local compileSteps

---@param context table per-call compiler state
---@param step table
---@param path string
---@param cont string|nil
---@param depth integer
---@param id string precomputed node id (compileSteps resolves ids in one pass)
---@return string
local function compileStep(context, step, path, cont, depth, id)
  local op = step.op
  if context.nodes[id] ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "duplicate node id",
      { scriptId = context.script.id, path = path, nodeId = id }
    )
  end

  local node = { op = op }
  for k, v in pairs(step) do
    if k ~= "key" and k ~= "provenance" then
      node[k] = v
    end
  end
  if step.provenance ~= nil then
    node.source = step.provenance
  end

  if op == "if" or op == "switch" then
    if depth + 1 > Compiler.MAX_STATIC_NESTING then
      Errors.raise(
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "maximum static nesting exceeded",
        { scriptId = context.script.id, path = path, depth = depth + 1 }
      )
    end
  end
  if op == "if" then
    node.yes = compileSteps(context, step.yes, path .. "/yes", cont, depth + 1) or cont
    node.no = compileSteps(context, step.no, path .. "/no", cont, depth + 1) or cont
    if #step.yes == 0 then
      addWarning(context, "empty yes branch", id)
    end
    if #step.no == 0 then
      addWarning(context, "empty no branch", id)
    end
  elseif op == "switch" then
    node.cases = {}
    local keys = {}
    for k in pairs(step.cases) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      node.cases[k] = compileSteps(context, step.cases[k], path .. "/" .. tostring(k), cont, depth + 1) or cont
      if #step.cases[k] == 0 then
        addWarning(context, "empty switch case", id)
      end
    end
    node.default = compileSteps(context, step.default, path .. "/default", cont, depth + 1) or cont
  elseif op == "goto" or op == "goto_if" or op == "goto_compared" then
    if op == "goto_compared" and step.script ~= nil then
      -- Cross-script compare-state form: resolved through the composition
      -- registry at runtime like goto_script; no local label.
      if step.target ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "goto_compared must not combine a local target with a script",
          { scriptId = context.script.id, path = path, target = step.target, script = step.script }
        )
      end
      node.next = cont
    else
      local labelId = context.labelNodeIds[step.target]
      if labelId == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_LABEL_MISSING,
          "control target is not a local label",
          { scriptId = context.script.id, path = path, target = step.target }
        )
      end
      node.targetNode = labelId
      if op ~= "goto" then
        node.next = cont
      end
    end
  elseif op == "goto_script" then
    -- A cross-script jump resolved through the composition registry at
    -- runtime; the graph carries the label reference as-is. The label lives
    -- in the target script's namespace, so a same-named local label is not
    -- a collision.
  elseif op == "call" or op == "call_compared" then
    node.returnNode = cont
    local labelId = context.labelNodeIds[step.target]
    if labelId ~= nil then
      if step.label ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "call label must not be combined with a local label target",
          { scriptId = context.script.id, path = path, target = step.target, label = step.label }
        )
      end
      node.targetNode = labelId
    end
  elseif op == "next" then
    context.usesNext = true
    if not context.opts.allowNext then
      Errors.raise(
        ScriptErrors.SCRIPT_WRAPPER_INVALID,
        "next requires wrapper registration",
        { scriptId = context.script.id, path = path }
      )
    end
  end

  context.nodes[id] = node
  return id
end

-- Compile a linear sequence whose tail continues at `cont`. Returns the first
-- node ID, or nil for an empty sequence. Node IDs come from the precomputed
-- immutable map, so each step's continuation (the following step, or `cont`
-- at the tail) is known before its branches compile.
---@param context table per-call compiler state
---@param steps table
---@param path string
---@param cont string|nil
---@param depth integer
---@return string|nil
compileSteps = function(context, steps, path, cont, depth)
  local ids = {}
  for i = 1, #steps do
    ids[i] = assert(context.nodeIds[path .. "/" .. tostring(i - 1)], "node id was not precomputed")
  end
  for i = 1, #steps do
    local step = steps[i]
    compileStep(context, step, path .. "/" .. tostring(i - 1), ids[i + 1] or cont, depth, ids[i])
    local node = context.nodes[ids[i]]
    if not NO_CHAIN_NEXT[node.op] then
      node.next = ids[i + 1] or cont
    end
  end
  return ids[1]
end

-- Reachability, unsupported-node analysis, and load-time warnings on the
-- completed graph.
---@param context table per-call compiler state
---@param graph table
local function analyze(context, graph)
  local visited = {}
  local reachable = {}
  for _, id in ipairs(Graph.reachableNodes(graph)) do
    visited[id] = true
    if graph.nodes[id].op == "unsupported" then
      reachable[#reachable + 1] = id
    end
  end
  table.sort(reachable)
  graph.hasUnsupported = #reachable > 0
  graph.unsupportedNodes = reachable

  local unreachable = {}
  for id in pairs(graph.nodes) do
    if not visited[id] then
      unreachable[#unreachable + 1] = id
    end
  end
  table.sort(unreachable)
  for _, id in ipairs(unreachable) do
    addWarning(context, "unreachable node", id)
  end

  local generated = context.script.metadata ~= nil and context.script.metadata.generated == true
  if not generated then
    for id, node in pairs(graph.nodes) do
      if FALLBACK_OPS[node.op] then
        addWarning(context, "handwritten script uses label/goto fallback", id)
      end
    end
  end
end

-- Projection for the revision hash : API version, operation names,
-- operands, resolved control edges, declared params/locals. The projection's
-- node map is keyed by node ID, and node IDs embed identity: generated
-- `src:` IDs carry metadata.source member/scriptIndex and
-- provenance.offsets[1], `key:` IDs carry the author key. Edits to
-- provenance offsets or metadata source identity therefore change the
-- revision of a script with generated nodes; author key edits change it for
-- keyed nodes. Only the node `source` payload (provenance opcodes etc.),
-- warnings, and the non-identity metadata/coverage fields are excluded.
---@param graph table
---@return table
local function buildProjection(graph)
  local nodes = {}
  for id, node in pairs(graph.nodes) do
    local copy = {}
    for k, v in pairs(node) do
      if k ~= "source" then
        copy[k] = v
      end
    end
    nodes[id] = copy
  end
  local payload = { api = graph.api, entry = graph.entry, nodes = nodes }
  if graph.params ~= nil then
    payload.params = graph.params
  end
  if graph.locals ~= nil then
    payload.locals = graph.locals
  end
  if graph.labels ~= nil and next(graph.labels) ~= nil then
    payload.labels = graph.labels
  end
  return payload
end

function Compiler._compile(script, opts)
  opts = opts or {}
  -- Per-call compiler state: nodes, labels, warnings, used node ids, and
  -- opts live in this context so calls are reentrant and cannot contaminate
  -- one another.
  local context = {
    script = script,
    opts = opts,
    nodes = {},
    labelNodeIds = {},
    warnings = {},
    usesNext = false,
    usedNodeIds = {},
    nodeIds = {},
  }

  local ok, err = Validator.validate(script)
  if not ok then
    error(err)
  end

  local steps = normalizeSteps(script.steps)
  assignNodeIds(context, steps, "steps")
  prewalk(context, steps, "steps")
  local entry = compileSteps(context, steps, "steps", nil, 0)

  local graph = {
    graphSchema = Graph.SCHEMA_NAME,
    api = script.api,
    scriptId = script.id,
    entry = entry,
    nodes = context.nodes,
    labels = context.labelNodeIds,
    usesNext = context.usesNext,
    warnings = {},
  }
  if script.params ~= nil and next(script.params) ~= nil then
    graph.params = deepCopy(script.params)
  end
  if script.locals ~= nil and next(script.locals) ~= nil then
    graph.locals = deepCopy(script.locals)
  end

  analyze(context, graph)
  table.sort(context.warnings, function(a, b)
    if a.nodeId ~= b.nodeId then
      return a.nodeId < b.nodeId
    end
    return a.message < b.message
  end)
  graph.warnings = context.warnings

  graph.revision = Sha256.hex(LuaWriter.encode(buildProjection(graph)))
  return graph
end

-- Compiles a validated script resource into the internal graph. Returns the
-- graph, or nil plus an Errors object on validation or structural failure.
---@param script any
---@param opts table|nil
---@return table|nil, Errors.Error|nil
function Compiler.compile(script, opts)
  local ok, result = pcall(Compiler._compile, script, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    local thrown = result --[[@as any]]
    return nil, thrown
  end
  error(result, 0)
end

return Compiler
