-- Data-level validation for gen4 field-script resources, API 1. The validator
-- checks the script resource schema, API version, serializability (no
-- functions, userdata, threads, metatables, cycles, or non-finite numbers),
-- operation field shapes, enum values, reference forms, and declared
-- locals/args. It never executes gameplay and never mutates its input.
-- Graph-level checks (labels, call targets, reachability, lock balance) belong
-- to the compiler and later workstreams. Unknown fields are rejected in strict
-- mode (the default and the mode generated content always uses).

local Errors = require("libs.rom.src.Errors")
local Schema = require("libs.engine.src.script.Schema")

local Validator = {}

-- Per-call validation state; the lookup sets below are immutable and built
-- once at load.
local C = { scriptId = nil, strict = true, usedLocals = {}, usedArgs = {} }

local ENUM_SETS = {}
for name, values in pairs(Schema.ENUMS) do
  local set = {}
  for _, v in ipairs(values) do set[v] = true end
  ENUM_SETS[name] = set
end

local PARAM_TYPES_SET = {}
for _, ty in ipairs(Schema.PARAM_TYPES) do PARAM_TYPES_SET[ty] = true end

local ACTOR_SPECIALS_SET = {}
for _, special in ipairs(Schema.ACTOR_SPECIALS) do ACTOR_SPECIALS_SET[special] = true end

-- Field-type checkers, filled below; declared up front so checkFields can
-- close over it.
local CHECKERS = {}

---@param code string
---@param path string
---@param message string
---@param extra table|nil
local function fail(code, path, message, extra)
  local context = { path = path }
  if C.scriptId then context.scriptId = C.scriptId end
  if extra then
    for k, v in pairs(extra) do context[k] = v end
  end
  Errors.raise(code, message, context)
end

local function isScalar(v)
  local ty = type(v)
  return ty == "number" or ty == "string" or ty == "boolean"
end

local function checkSerializable(value, path, seen)
  local ty = type(value)
  if ty == "table" then
    if getmetatable(value) ~= nil then
      fail("SCRIPT_SCHEMA_INVALID", path, "script data must not carry metatables")
    end
    if seen[value] then
      fail("SCRIPT_SCHEMA_INVALID", path, "script data must be acyclic (cycle detected)")
    end
    seen[value] = true
    for k, v in pairs(value) do
      if type(k) ~= "number" and type(k) ~= "string" then
        fail("SCRIPT_SCHEMA_INVALID", path, "script data keys must be numbers or strings")
      end
      checkSerializable(v, path .. "/" .. tostring(k), seen)
    end
    seen[value] = nil
  elseif ty == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      fail("SCRIPT_SCHEMA_INVALID", path, "script data must not contain non-finite numbers")
    end
  elseif ty ~= "string" and ty ~= "boolean" then
    fail("SCRIPT_SCHEMA_INVALID", path,
      "script data must be numbers, strings, booleans, or tables (got " .. ty .. ")")
  end
end

-- Reference and shape checkers. Each raises on failure.

local function checkArray(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected an array", { field = field })
  end
  local count = #v
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 or k > count then
      fail("SCRIPT_SCHEMA_INVALID", path, "expected a contiguous array", { field = field })
    end
  end
  return count
end

-- Check a table's fields against a schema spec. `skipKeys` names keys that
-- are legal on the table but are not schema fields (discriminator keys such
-- as `op` or `value`). Unknown fields are rejected in strict mode. Field-level
-- failures and nested checkers report the exact field path; the root `steps`
-- field reads as `steps/N` to match the node-path style used by graph node IDs.
local function fieldPath(path, name)
  if path == "script" and name == "steps" then return "steps" end
  return path .. "/" .. name
end

local function checkFields(owner, fieldSpecs, given, path, skipKeys)
  for name, spec in pairs(fieldSpecs) do
    local v = given[name]
    if v == nil then
      if spec.required then
        fail("SCRIPT_SCHEMA_INVALID", fieldPath(path, name), "missing required field", { field = name, op = owner })
      end
    else
      local ty = spec.type
      if ty:sub(1, 5) == "enum:" then
        local set = ENUM_SETS[ty:sub(6)]
        assert(set, "unknown enum in schema: " .. ty)
        if not set[v] then
          fail("SCRIPT_SCHEMA_INVALID", fieldPath(path, name), "invalid enum value for " .. ty,
            { field = name, op = owner, value = v })
        end
      else
        local checker = CHECKERS[ty]
        assert(checker, "no checker registered for field type: " .. ty)
        checker(v, fieldPath(path, name), name)
      end
    end
  end
  if C.strict then
    for name in pairs(given) do
      if fieldSpecs[name] == nil and not (skipKeys and skipKeys[name]) then
        fail("SCRIPT_SCHEMA_INVALID", fieldPath(path, name), "unknown field", { field = name, op = owner })
      end
    end
  end
end

local EXTERNAL_MESSAGE_FIELDS = {
  bank = { type = "scalar_or_value", required = true },
  id = { type = "scalar_or_value", required = true },
}

local function checkValueRef(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a value reference", { field = field })
  end
  local kind = v.value
  if type(kind) ~= "string" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a value reference with a kind",
      { field = field })
  end
  local spec = Schema.VALUES[kind]
  if not spec then
    fail("SCRIPT_INVALID_REFERENCE", path, "unknown value kind", { field = field, kind = kind })
  end
  checkFields(kind, spec.fields, v, path, { value = true })
end

local function checkVarRef(v, path, field)
  checkValueRef(v, path, field)
  if v.value ~= "var" then
    fail("SCRIPT_INVALID_REFERENCE", path, "expected a variable reference",
      { field = field, kind = v.value })
  end
end

local function checkTextValue(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a text value", { field = field })
  end
  local kind = v.text
  if type(kind) ~= "string" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a text value with a kind",
      { field = field })
  end
  local spec = Schema.TEXT_VALUES[kind]
  if not spec then
    fail("SCRIPT_INVALID_REFERENCE", path, "unknown text kind", { field = field, kind = kind })
  end
  checkFields(kind, spec.fields, v, path, { text = true })
end

local function checkCondition(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a condition", { field = field })
  end
  local kind = v.condition
  if type(kind) ~= "string" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a condition with a kind",
      { field = field })
  end
  local spec = Schema.CONDITIONS[kind]
  if not spec then
    fail("SCRIPT_INVALID_REFERENCE", path, "unknown condition kind", { field = field, kind = kind })
  end
  checkFields(kind, spec.fields, v, path, { condition = true })
end

local function checkActor(v, path, field)
  if type(v) == "string" then
    if #v == 0 then
      fail("SCRIPT_SCHEMA_INVALID", path, "actor id must not be empty", { field = field })
    end
    return
  end
  if type(v) ~= "table" or v.ref ~= "actor" then
    fail("SCRIPT_INVALID_REFERENCE", path, "expected an actor reference", { field = field })
  end
  if type(v.id) == "string" and #v.id > 0 then return end
  if type(v.special) == "string" and ACTOR_SPECIALS_SET[v.special] then return end
  fail("SCRIPT_SCHEMA_INVALID", path, "actor reference must carry id or a known special",
    { field = field, special = v.special })
end

local function checkMessage(v, path, field)
  if type(v) == "string" then
    if #v == 0 then
      fail("SCRIPT_SCHEMA_INVALID", path, "message id must not be empty", { field = field })
    end
    return
  end
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a message reference", { field = field })
  end
  if v.value ~= nil then
    checkValueRef(v, path, field)
    return
  end
  if v.message == "external" then
    checkFields("external_message", EXTERNAL_MESSAGE_FIELDS, v, path, { message = true })
    return
  end
  if v.text == "gendered_message" then
    checkTextValue(v, path, field)
    return
  end
  fail("SCRIPT_INVALID_REFERENCE", path, "unknown message reference form", { field = field })
end

local function checkMovement(v, path, field)
  local count = checkArray(v, path, field)
  for i = 1, count do
    local item = v[i]
    local actionPath = path .. "/" .. tostring(i - 1)
    if type(item) ~= "table" then
      fail("SCRIPT_SCHEMA_INVALID", actionPath, "movement action must be a table", { field = field })
    end
    local name = item.action
    if type(name) ~= "string" then
      fail("SCRIPT_UNKNOWN_OPERATION", actionPath, "movement action is missing a name",
        { field = field })
    end
    local spec = Schema.MOVEMENT_ACTIONS[name]
    if not spec then
      fail("SCRIPT_UNKNOWN_OPERATION", actionPath, "unknown movement action",
        { field = field, action = name })
    end
    checkFields(name, spec.fields, item, actionPath, { action = true })
  end
end

local function checkStep(step, path)
  if type(step) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "step must be a table")
  end
  local name = step.op
  if type(name) ~= "string" then
    fail("SCRIPT_SCHEMA_INVALID", path, "step is missing an op")
  end
  local spec = Schema.OPERATIONS[name]
  if not spec then
    fail("SCRIPT_UNKNOWN_OPERATION", path, "unknown operation", { op = name })
  end
  checkFields(name, spec.fields, step, path, { op = true })
  if name == "set_local" or name == "add_local" or name == "sub_local" then
    C.usedLocals[step.name] = path
  elseif name == "copy_local" then
    C.usedLocals[step.destination] = path
    C.usedLocals[step.source] = path
  end
end

local function checkSteps(v, path, field)
  local count = checkArray(v, path, field)
  for i = 1, count do
    checkStep(v[i], path .. "/" .. tostring(i - 1))
  end
end

local function collectRefs(value, path)
  if type(value) ~= "table" then return end
  if value.value == "local" and type(value.name) == "string" then
    C.usedLocals[value.name] = path
  elseif value.value == "arg" and type(value.name) == "string" then
    C.usedArgs[value.name] = path
  end
  for k, v in pairs(value) do
    if type(k) ~= "table" then collectRefs(v, path .. "/" .. tostring(k)) end
  end
end

local function checkDeclarationMap(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a declaration table", { field = field })
  end
  for name, ty in pairs(v) do
    if type(name) ~= "string" or #name == 0 then
      fail("SCRIPT_SCHEMA_INVALID", path, "declaration names must be non-empty strings",
        { field = field })
    end
    if not PARAM_TYPES_SET[ty] then
      fail("SCRIPT_SCHEMA_INVALID", path, "unknown declared type",
        { field = field, name = name, declaredType = ty })
    end
  end
end

local function checkArgValue(v, path, field)
  if isScalar(v) then return end
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "arg must be a scalar, value, actor, or text reference",
      { field = field })
  end
  if v.value ~= nil then
    checkValueRef(v, path, field)
    return
  end
  if v.text ~= nil then
    checkTextValue(v, path, field)
    return
  end
  checkActor(v, path, field)
end

CHECKERS.string = function(v, path, field)
  if type(v) ~= "string" or #v == 0 then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a non-empty string", { field = field })
  end
end
CHECKERS.integer = function(v, path, field)
  if type(v) ~= "number" or v % 1 ~= 0 then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected an integer", { field = field, value = v })
  end
end
CHECKERS.number = function(v, path, field)
  if type(v) ~= "number" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a number", { field = field })
  end
end
CHECKERS.boolean = function(v, path, field)
  if type(v) ~= "boolean" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a boolean", { field = field })
  end
end
CHECKERS.scalar = function(v, path, field)
  if not isScalar(v) then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a scalar literal", { field = field })
  end
end
CHECKERS.scalar_or_value = function(v, path, field)
  if isScalar(v) then return end
  checkValueRef(v, path, field)
end
CHECKERS.value = checkValueRef
CHECKERS.text_value = checkTextValue
CHECKERS.id_or_var = function(v, path, field)
  if type(v) == "string" and #v > 0 then return end
  checkVarRef(v, path, field)
end
CHECKERS.actor = checkActor
CHECKERS.actor_list = function(v, path, field)
  local count = checkArray(v, path, field)
  for i = 1, count do
    checkActor(v[i], path .. "/" .. tostring(i - 1), field)
  end
end
CHECKERS.condition = checkCondition
CHECKERS.condition_list = function(v, path, field)
  local count = checkArray(v, path, field)
  for i = 1, count do
    checkCondition(v[i], path .. "/" .. tostring(i - 1), field)
  end
end
CHECKERS.message = checkMessage
CHECKERS.movement = checkMovement
CHECKERS.steps = checkSteps
CHECKERS.cases = function(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a cases table", { field = field })
  end
  for k, caseSteps in pairs(v) do
    if type(k) ~= "number" or k % 1 ~= 0 then
      fail("SCRIPT_SCHEMA_INVALID", path, "switch cases must be integer-keyed",
        { field = field, key = tostring(k) })
    end
    checkSteps(caseSteps, path .. "/" .. tostring(k))
  end
end
CHECKERS.args = function(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected an args table", { field = field })
  end
  for k, arg in pairs(v) do
    if type(k) ~= "string" then
      fail("SCRIPT_SCHEMA_INVALID", path, "args must be named", { field = field })
    end
    checkArgValue(arg, path .. "/" .. k, field)
  end
end
CHECKERS.bindings = function(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a bindings table", { field = field })
  end
  for slot, textValue in pairs(v) do
    if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 0 or slot > 7 then
      fail("SCRIPT_SCHEMA_INVALID", path, "binding slots must be integers in 0..7",
        { field = field, slot = tostring(slot) })
    end
    checkTextValue(textValue, path .. "/" .. tostring(slot), field)
  end
end
CHECKERS.buffer_slot = function(v, path, field)
  if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > 7 then
    fail("SCRIPT_SCHEMA_INVALID", path, "buffer slot must be an integer in 0..7",
      { field = field, slot = v })
  end
end
CHECKERS.buttons = function(v, path, field)
  local count = checkArray(v, path, field)
  local set = ENUM_SETS.button
  for i = 1, count do
    if not set[v[i]] then
      fail("SCRIPT_SCHEMA_INVALID", path, "invalid button",
        { field = field, button = v[i] })
    end
  end
end
CHECKERS.scalar_list = function(v, path, field)
  local count = checkArray(v, path, field)
  for i = 1, count do
    if not isScalar(v[i]) then
      fail("SCRIPT_SCHEMA_INVALID", path, "arguments must be scalars",
        { field = field })
    end
  end
end
CHECKERS.source_provenance = function(v, path, field)
  if type(v) ~= "table" then
    fail("SCRIPT_SCHEMA_INVALID", path, "expected a source provenance table", { field = field })
  end
  local offsets = v.offsets
  local opcodes = v.opcodes
  local count = checkArray(offsets, path .. "/offsets", field)
  if type(opcodes) ~= "table" or #opcodes ~= count then
    fail("SCRIPT_SCHEMA_INVALID", path,
      "source offsets and opcodes must be arrays of equal length", { field = field })
  end
  for i = 1, count do
    if type(offsets[i]) ~= "number" or offsets[i] % 1 ~= 0 then
      fail("SCRIPT_SCHEMA_INVALID", path .. "/offsets/" .. tostring(i - 1),
        "source offsets must be integers", { field = field })
    end
    if type(opcodes[i]) ~= "number" or opcodes[i] % 1 ~= 0 then
      fail("SCRIPT_SCHEMA_INVALID", path .. "/opcodes/" .. tostring(i - 1),
        "source opcodes must be integers", { field = field })
    end
  end
end
CHECKERS.params = checkDeclarationMap
CHECKERS.locals = checkDeclarationMap
CHECKERS.serializable = function() end

function Validator._validate(script, opts)
  opts = opts or {}
  C.scriptId = nil
  C.strict = opts.strict ~= false
  C.usedLocals = {}
  C.usedArgs = {}
  if type(script) ~= "table" then
    Errors.raise("SCRIPT_SCHEMA_INVALID", "script must be a table", { path = "script" })
  end
  C.scriptId = type(script.id) == "string" and script.id or nil
  checkSerializable(script, "script", {})
  checkFields("script", Schema.SCRIPT.fields, script, "script")
  if script.api ~= Schema.API_VERSION then
    Errors.raise("SCRIPT_API_UNSUPPORTED",
      string.format("api %s is not supported (supported major: %d)",
        tostring(script.api), Schema.API_VERSION),
      { path = "api", scriptId = C.scriptId, api = script.api })
  end
  collectRefs(script.steps, "steps")
  for name, path in pairs(C.usedLocals) do
    local declared = script.locals and script.locals[name]
    if declared == nil then
      fail("SCRIPT_SCHEMA_INVALID", path, "local is not declared", { name = name })
    end
  end
  for name, path in pairs(C.usedArgs) do
    local declared = script.params and script.params[name]
    if declared == nil then
      fail("SCRIPT_SCHEMA_INVALID", path, "arg is not declared", { name = name })
    end
  end
  return true
end

---@param script any
---@param opts table|nil
---@return boolean|nil, Errors.Error|nil
function Validator.validate(script, opts)
  local ok, err = pcall(Validator._validate, script, opts)
  if ok then return true end
  if Errors.is(err) then
    local thrown = err --[[@as any]]
    return nil, thrown
  end
  error(err, 0)
end

return Validator
