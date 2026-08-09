-- Deterministic markdown renderer for the gen4 field-script API 1 schema.
-- Pure module: takes Schema and returns the full docs/script-api-v1.md body.
-- Re-rendering against an unchanged schema produces byte-identical output, so
-- the checked-in doc file can be drift-tested in the suite.

local Schema = require("libs.engine.src.script.Schema")

local DocGen = {}

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function renderDefault(default)
  if type(default) ~= "table" then
    return "`" .. tostring(default) .. "`"
  end
  local parts = {}
  for _, v in ipairs(default) do
    parts[#parts + 1] = string.format("%q", v)
  end
  return "`{" .. table.concat(parts, ", ") .. "}`"
end

local function fieldTable(fields)
  local names = sortedKeys(fields)
  local lines = { "| Field | Type | Required | Default |", "|---|---|---|---|" }
  for _, name in ipairs(names) do
    local spec = fields[name]
    local required = spec.required and "yes" or ""
    local default = spec.default == nil and "" or renderDefault(spec.default)
    lines[#lines + 1] = string.format("| `%s` | %s | %s | %s |", name, spec.type, required, default)
  end
  return table.concat(lines, "\n")
end

local function constructorTables()
  local parts = {}
  for _, group in ipairs(Schema.CONSTRUCTORS) do
    parts[#parts + 1] = "### " .. group.section
    parts[#parts + 1] = ""
    parts[#parts + 1] = "| Signature | Canonical | Notes |"
    parts[#parts + 1] = "|---|---|---|"
    for _, row in ipairs(group.rows) do
      parts[#parts + 1] =
        string.format("| `%s` | `%s` | %s |", row.signature, row.canonical, row.notes ~= "" and row.notes or "")
    end
    parts[#parts + 1] = ""
  end
  return table.concat(parts, "\n")
end

local function operationSections()
  local parts = { "## Canonical operations" }
  for _, name in ipairs(sortedKeys(Schema.OPERATIONS)) do
    local fields = Schema.OPERATIONS[name].fields
    parts[#parts + 1] = ""
    parts[#parts + 1] = "### `" .. name .. "`"
    parts[#parts + 1] = ""
    if next(fields) == nil then
      parts[#parts + 1] = "No fields."
    else
      parts[#parts + 1] = fieldTable(fields)
    end
  end
  parts[#parts + 1] = ""
  return table.concat(parts, "\n")
end

local function kindSections(title, kinds)
  local parts = { "## " .. title }
  for _, name in ipairs(sortedKeys(kinds)) do
    local fields = kinds[name].fields
    parts[#parts + 1] = ""
    parts[#parts + 1] = "### `" .. name .. "`"
    parts[#parts + 1] = ""
    if next(fields) == nil then
      parts[#parts + 1] = "No fields."
    else
      parts[#parts + 1] = fieldTable(fields)
    end
  end
  parts[#parts + 1] = ""
  return table.concat(parts, "\n")
end

local function enumSection()
  local parts = { "## Enums" }
  for _, name in ipairs(sortedKeys(Schema.ENUMS)) do
    parts[#parts + 1] = ""
    parts[#parts + 1] = string.format("`%s`: %s", name, table.concat(Schema.ENUMS[name], ", "))
  end
  parts[#parts + 1] = ""
  return table.concat(parts, "\n")
end

function DocGen.render()
  local parts = {
    "# gen4 field-script DSL — API " .. Schema.API_VERSION,
    "",
    "Generated from `libs/engine/src/script/Schema.lua` by `tools/gen-script-docs`; do not edit by hand.",
    "",
    "```lua",
    'local S = require("gen4.script")',
    "S.apiVersion == " .. Schema.API_VERSION,
    "```",
    "",
    "Constructors return ordinary serializable Lua tables. Direct table form is always legal and must match the same shapes. The validator (`S.validate`) rejects functions, userdata, threads, metatables, cycles, and unknown fields in strict mode.",
    "",
    "## Constructor index",
    "",
    constructorTables(),
    "## Values",
    "",
    kindSections("Value references", Schema.VALUES),
    kindSections("Text values", Schema.TEXT_VALUES),
    kindSections("Conditions", Schema.CONDITIONS),
    kindSections("Movement actions", Schema.MOVEMENT_ACTIONS),
    operationSections(),
    enumSection(),
  }
  return table.concat(parts, "\n")
end

return DocGen
