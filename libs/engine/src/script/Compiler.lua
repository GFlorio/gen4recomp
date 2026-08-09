-- Compiles a validated gen4 field-script resource into the immutable internal
-- graph that the runtime executes. Node IDs follow section
-- 24.1 (author `key`, generated `src:<member>:<index>:<offset>[/<op>]`, else
-- structural `path:steps/3/no/2`); the revision hash follows section 24.2 and
-- covers only normalized semantics. Load-time structural validation from
-- section 25.1 also lives here: label uniqueness/targets, wrapper-only `next`,
-- local call-target resolution, recursive call cycles without a blocking edge,
-- and static nesting. The compiler deep-copies and freezes; authoring tables
-- are never shared and never mutated.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local LuaWriter = require("libs.rom.src.LuaWriter")
local Schema = require("libs.engine.src.script.Schema")
local Validator = require("libs.engine.src.script.Validator")
local Sha256 = require("libs.engine.src.script.Sha256")
local Graph = require("libs.engine.src.script.Graph")

local Compiler = {}

-- Maximum static if/switch nesting depth .
Compiler.MAX_STATIC_NESTING = 64

-- Ops that end a run phase (yield or block) or terminate the script. A local
-- call cycle whose subroutines contain none of these before their first call
-- can never suspend and would burn the step budget, so the compiler rejects it
-- at load time .
local CYCLE_BREAKING_OPS = {
  yield_tick = true,
  wait_ticks = true,
  wait_input = true,
  wait_input_or_ticks = true,
  say = true,
  message = true,
  ask_yes_no = true,
  wait_movement = true,
  move = true,
  wait_sound = true,
  wait_cry = true,
  wait_fanfare = true,
  wait_fade = true,
  warp = true,
  lock_all = true,
  lock_actor = true,
  call_common = true,
  lua = true,
  stop = true,
}

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

local ROOT_OWNER = "<root>"

local ACTOR_SPECIALS_SET = {}
for _, special in ipairs(Schema.ACTOR_SPECIALS) do
  ACTOR_SPECIALS_SET[special] = true
end

-- Per-call compiler state, reset by _compile.
local C = {
  script = nil,
  opts = nil,
  nodes = {},
  labelNodeIds = {},
  subroutineEdges = {},
  ownerSteps = {},
  warnings = {},
  usesNext = false,
  usedNodeIds = {},
}

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
-- actor/message forms per sections 10-11 and 45).

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

-- String actor shorthand becomes an actor reference .
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
---@param step table
---@param path string
---@return string
local function nodeIdFor(step, path)
  if step.key ~= nil then
    return "key:" .. step.key
  end
  local provenance = step.provenance
  if provenance ~= nil then
    local metaSource = C.script.metadata and C.script.metadata.source
    local member = metaSource and metaSource.member
    local scriptIndex = metaSource and metaSource.scriptIndex
    if member == nil or scriptIndex == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_SCHEMA_INVALID,
        "step provenance requires script metadata.source member and scriptIndex",
        { scriptId = C.script.id, path = path, op = step.op }
      )
    end
    assert(#provenance.offsets > 0, "provenance must name a source offset")
    local base = string.format("src:%04d:%03d:%04x", member, scriptIndex, provenance.offsets[1])
    local id = base
    if #provenance.offsets > 1 then
      id = base .. "/" .. step.op
    end
    local seen = C.usedNodeIds[id]
    if seen ~= nil then
      C.usedNodeIds[id] = seen + 1
      id = base .. "/" .. step.op .. "/" .. tostring(seen + 1)
    else
      C.usedNodeIds[id] = 1
    end
    return id
  end
  return "path:" .. path
end

local function addWarning(message, nodeId)
  C.warnings[#C.warnings + 1] = { message = message, nodeId = nodeId }
end

-- Pre-pass: register every label name with its node ID.
---@param steps table
---@param path string
local function prewalk(steps, path)
  for i = 1, #steps do
    local step = steps[i]
    local p = path .. "/" .. tostring(i - 1)
    if step.op == "label" then
      local name = step.name
      if C.labelNodeIds[name] ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "duplicate label name",
          { scriptId = C.script.id, path = p, label = name }
        )
      end
      C.labelNodeIds[name] = nodeIdFor(step, p)
    end
    if step.op == "if" then
      prewalk(step.yes, p .. "/yes")
      prewalk(step.no, p .. "/no")
    elseif step.op == "switch" then
      for k, caseSteps in pairs(step.cases) do
        prewalk(caseSteps, p .. "/" .. tostring(k))
      end
    end
  end
end

-- Get-or-create a per-key set inside a map.
---@param map table
---@param key string
---@return table
local function setFor(map, key)
  local set = map[key]
  if set == nil then
    set = {}
    map[key] = set
  end
  return set
end

-- Record a subroutine-flow edge from `owner` into the span of `label`: either
-- a call step or a linear fallthrough that lands on a later label's marker.
---@param owner string
---@param label string
local function addSubroutineEdge(owner, label)
  setFor(C.subroutineEdges, owner)[label] = true
end

-- Compile one step into a node. `cont` is the node ID the step's control flow
-- continues at (nil at the script end). Returns the node ID.
local compileSteps

---@param step table
---@param path string
---@param cont string|nil
---@param owner string
---@param depth integer
---@param id string precomputed node id (compileSteps resolves ids in one pass)
---@return string
local function compileStep(step, path, cont, owner, depth, id)
  local op = step.op
  if C.nodes[id] ~= nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SCHEMA_INVALID,
      "duplicate node id",
      { scriptId = C.script.id, path = path, nodeId = id }
    )
  end

  local ownerBucket = setFor(C.ownerSteps, owner)
  -- The cycle analysis must examine fields, not merely op names: `message`
  -- blocks only with waitForPrint and `lock_actor` only with
  -- waitUntilPausable, so an entry records whether it actually blocks.
  local blocks = op ~= "message" or step.waitForPrint == true
  if op == "lock_actor" then
    blocks = step.waitUntilPausable == true
  end
  ownerBucket[#ownerBucket + 1] = { op = op, blocks = blocks }

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
        { scriptId = C.script.id, path = path, depth = depth + 1 }
      )
    end
  end
  if op == "if" then
    node.yes = compileSteps(step.yes, path .. "/yes", cont, owner, depth + 1) or cont
    node.no = compileSteps(step.no, path .. "/no", cont, owner, depth + 1) or cont
    if #step.yes == 0 then
      addWarning("empty yes branch", id)
    end
    if #step.no == 0 then
      addWarning("empty no branch", id)
    end
  elseif op == "switch" then
    node.cases = {}
    local keys = {}
    for k in pairs(step.cases) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      node.cases[k] = compileSteps(step.cases[k], path .. "/" .. tostring(k), cont, owner, depth + 1) or cont
      if #step.cases[k] == 0 then
        addWarning("empty switch case", id)
      end
    end
    node.default = compileSteps(step.default, path .. "/default", cont, owner, depth + 1) or cont
  elseif op == "goto" or op == "goto_if" or op == "goto_compared" then
    if op == "goto_compared" and step.script ~= nil then
      -- Cross-script compare-state form: resolved through the composition
      -- registry at runtime like goto_script; no local label.
      if step.target ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "goto_compared must not combine a local target with a script",
          { scriptId = C.script.id, path = path, target = step.target, script = step.script }
        )
      end
      node.next = cont
    else
      local labelId = C.labelNodeIds[step.target]
      if labelId == nil then
        Errors.raise(
          ScriptErrors.SCRIPT_LABEL_MISSING,
          "control target is not a local label",
          { scriptId = C.script.id, path = path, target = step.target }
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
    local labelId = C.labelNodeIds[step.target]
    if labelId ~= nil then
      if step.label ~= nil then
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "call label must not be combined with a local label target",
          { scriptId = C.script.id, path = path, target = step.target, label = step.label }
        )
      end
      node.targetNode = labelId
      addSubroutineEdge(owner, step.target)
    end
  elseif op == "label" then
    addSubroutineEdge(owner, step.name)
  elseif op == "next" then
    C.usesNext = true
    if not C.opts.allowNext then
      Errors.raise(
        ScriptErrors.SCRIPT_WRAPPER_INVALID,
        "next requires wrapper registration",
        { scriptId = C.script.id, path = path }
      )
    end
  end

  C.nodes[id] = node
  return id
end

-- Compile a linear sequence whose tail continues at `cont`. Returns the first
-- node ID, or nil for an empty sequence. Node IDs are computed upfront so each
-- step's continuation (the following step, or `cont` at the tail) is known
-- before its branches compile.
---@param steps table
---@param path string
---@param cont string|nil
---@param owner string
---@param depth integer
---@return string|nil
compileSteps = function(steps, path, cont, owner, depth)
  local ids = {}
  for i = 1, #steps do
    ids[i] = nodeIdFor(steps[i], path .. "/" .. tostring(i - 1))
  end
  local currentOwner = owner
  for i = 1, #steps do
    local step = steps[i]
    compileStep(step, path .. "/" .. tostring(i - 1), ids[i + 1] or cont, currentOwner, depth, ids[i])
    local node = C.nodes[ids[i]]
    if not NO_CHAIN_NEXT[node.op] then
      node.next = ids[i + 1] or cont
    end
    if step.op == "label" then
      currentOwner = step.name
    end
  end
  return ids[1]
end

-- Reject local call cycles whose subroutines can never suspend or terminate
-- . Subroutine-flow edges run from a span owner to a label:
-- a call step, or a linear fallthrough that lands on a later label's marker.
-- An SCC in this graph is recursive control flow; it is allowed only when some
-- span in the cycle contains a cycle-breaking op before its first call step,
-- because the recursion path re-enters that span at its label and executes the
-- prefix each time.
local function cycleCheck()
  local index = 0
  local stack = {}
  local onStack = {}
  local indices = {}
  local lowlink = {}

  local function sccBreaks(scc)
    for _, owner in ipairs(scc) do
      for _, entry in ipairs(C.ownerSteps[owner] or {}) do
        if entry.blocks and CYCLE_BREAKING_OPS[entry.op] then
          return true
        end
        if entry.op == "call" or entry.op == "call_compared" then
          break
        end
      end
    end
    return false
  end

  local function strongConnect(v)
    index = index + 1
    indices[v] = index
    lowlink[v] = index
    stack[#stack + 1] = v
    onStack[v] = true
    local targets = {}
    for t in pairs(C.subroutineEdges[v] or {}) do
      targets[#targets + 1] = t
    end
    table.sort(targets)
    for _, t in ipairs(targets) do
      if indices[t] == nil then
        strongConnect(t)
        lowlink[v] = math.min(lowlink[v], lowlink[t])
      elseif onStack[t] then
        lowlink[v] = math.min(lowlink[v], indices[t])
      end
    end
    if lowlink[v] == indices[v] then
      local scc = {}
      while true do
        local w = table.remove(stack)
        onStack[w] = nil
        scc[#scc + 1] = w
        if w == v then
          break
        end
      end
      local edges = C.subroutineEdges[v] or {}
      local hasCycle = #scc > 1 or edges[v] ~= nil
      if hasCycle and not sccBreaks(scc) then
        table.sort(scc)
        Errors.raise(
          ScriptErrors.SCRIPT_SCHEMA_INVALID,
          "direct recursive call cycle without a blocking edge",
          { scriptId = C.script.id, cycle = scc }
        )
      end
    end
  end

  strongConnect(ROOT_OWNER)
end

-- Reachability, unsupported-node analysis, and load-time warnings on the
-- completed graph .
---@param graph table
local function analyze(graph)
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
    addWarning("unreachable node", id)
  end

  local generated = C.script.metadata ~= nil and C.script.metadata.generated == true
  if not generated then
    for id, node in pairs(graph.nodes) do
      if FALLBACK_OPS[node.op] then
        addWarning("handwritten script uses label/goto fallback", id)
      end
    end
  end
end

-- Semantic projection for the revision hash : API version,
-- operation names, operands, resolved control edges, declared params/locals.
-- Provenance (`source`), node `key`s, warnings, and script metadata are
-- excluded, so provenance-only edits never change the revision.
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
  C.script = script
  C.opts = opts
  C.nodes = {}
  C.labelNodeIds = {}
  C.subroutineEdges = {}
  C.ownerSteps = {}
  C.warnings = {}
  C.usesNext = false
  C.usedNodeIds = {}

  local ok, err = Validator.validate(script)
  if not ok then
    error(err)
  end

  C.ownerSteps[ROOT_OWNER] = {}

  local steps = normalizeSteps(script.steps)
  prewalk(steps, "steps")
  local entry = compileSteps(steps, "steps", nil, ROOT_OWNER, 0)
  cycleCheck()

  local graph = {
    graphSchema = Graph.SCHEMA_NAME,
    api = script.api,
    scriptId = script.id,
    entry = entry,
    nodes = C.nodes,
    labels = C.labelNodeIds,
    usesNext = C.usesNext,
    warnings = {},
  }
  if script.params ~= nil and next(script.params) ~= nil then
    graph.params = deepCopy(script.params)
  end
  if script.locals ~= nil and next(script.locals) ~= nil then
    graph.locals = deepCopy(script.locals)
  end

  analyze(graph)
  table.sort(C.warnings, function(a, b)
    if a.nodeId ~= b.nodeId then
      return a.nodeId < b.nodeId
    end
    return a.message < b.message
  end)
  graph.warnings = C.warnings

  graph.revision = Sha256.hex(LuaWriter.encode(buildProjection(graph)))
  return Graph.freeze(graph)
end

-- Compiles a validated script resource into an immutable graph. Returns the
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
