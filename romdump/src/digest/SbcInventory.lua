-- Read-only inventory of the SBC features an NSBMD model uses: its scaling
-- rule, the special draw commands the static evaluator does not yet support
-- (BB, BBY, NODEMIX, CALLDL) with their option variants, and whether any shape
-- submitted under an active billboard matrix restores a matrix from the stack
-- inside its own display list.
--
-- It exists to scope transform work from evidence rather than from the SDK's
-- full feature set: NitroSystem defines three scaling rules and several
-- matrix-palette paths, but the shipped HGSS world only uses a subset. Command
-- semantics are those of NitroSystem g3d/src/sbc.c; Nsbmd.lua decodes the
-- operands and this module only classifies them.
--
-- `inspectModel` is pure; `scan` walks a RomFs and is the LÖVE-side entry point.

local Errors = require("libs.errors.src.Errors")
local LandData = require("romdump.src.digest.LandData")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")

local SbcInventory = {}

local MTX_RESTORE = 0x14

-- Commands the inventory counts, keyed by opcode. NODEDESC is included because
-- its store/restore option variants and its Maya scale-compensate flag byte
-- decide how much joint-transform work the scaling rules need.
local TRACKED = {
  [0x06] = "NODEDESC",
  [0x07] = "BB",
  [0x08] = "BBY",
  [0x09] = "NODEMIX",
  [0x0A] = "CALLDL",
  [0x0C] = "ENVMAP",
  [0x0D] = "PRJMAP",
}

local SCALING_RULE_NAMES = { [0] = "standard", [1] = "maya", [2] = "si3d" }

-- Model -> { scalingRule, scalingRuleName, commands, nodedescFlagBytes,
--            billboardShapes }.
--   commands           "NAME/opt" -> count, e.g. "BB/3" for a store+restore BB
--   nodedescFlagBytes  distinct nonzero NODEDESC flag bytes (Maya SSC bits)
--   billboardShapes    shapes submitted while a billboard matrix is current
function SbcInventory.inspectModel(model)
  local shapeByIndex = {}
  for _, shp in ipairs(model.shapes) do
    shapeByIndex[shp.index] = shp
  end

  local commands, flagBytes, billboardShapes = {}, {}, {}
  local billboardActive = false

  for _, cmd in ipairs(model.sbc.commands) do
    local op = cmd.opcode
    local tracked = TRACKED[op]
    if tracked then
      local key = tracked .. "/" .. cmd.option
      commands[key] = (commands[key] or 0) + 1
    end

    if op == 0x06 then
      if cmd.flags ~= 0 then
        flagBytes[cmd.flags] = true
      end
      billboardActive = false
    elseif op == 0x03 then -- MTX replaces the current matrix outright
      billboardActive = false
    elseif op == 0x07 or op == 0x08 then
      billboardActive = true
    elseif op == 0x05 and billboardActive then
      local shp = shapeByIndex[cmd.shapeIndex]
      billboardShapes[#billboardShapes + 1] = {
        shapeIndex = cmd.shapeIndex,
        shapeName = shp and shp.name or nil,
        -- A billboard matrix applies to the whole shape only if the display
        -- list does not select a different matrix per primitive.
        usesMatrixRestore = shp ~= nil and shp.opcodeCounts[MTX_RESTORE] ~= nil,
      }
    end
  end

  local sorted = {}
  for flags in pairs(flagBytes) do
    sorted[#sorted + 1] = flags
  end
  table.sort(sorted)

  local rule = model.info.scalingRule
  return {
    modelName = model.name,
    scalingRule = rule,
    scalingRuleName = SCALING_RULE_NAMES[rule] or "unknown",
    commands = commands,
    nodedescFlagBytes = sorted,
    billboardShapes = billboardShapes,
  }
end

-- True when a model uses nothing beyond plain joints -- the case the current
-- static evaluator already handles.
function SbcInventory.isPlain(entry)
  if entry.scalingRule ~= 0 then
    return false
  end
  if #entry.nodedescFlagBytes > 0 then
    return false
  end
  for key in pairs(entry.commands) do
    if key:sub(1, 8) ~= "NODEDESC" then
      return false
    end
  end
  return true
end

-- ---- ROM walk ----

local function decodeMembers(romFs, alias, modelsOf)
  local narc, err = romFs:openNarc(alias)
  if not narc then
    error(err)
  end
  local out, skipped = {}, {}
  for memberId = 0, narc:memberCount() - 1 do
    local ok, result = pcall(modelsOf, narc, memberId)
    if ok then
      for _, model in ipairs(result) do
        local entry = SbcInventory.inspectModel(model)
        entry.archive, entry.memberId = alias, memberId
        out[#out + 1] = entry
      end
    else
      -- A member that is not a Nitro file at all (the archives contain
      -- placeholder stubs) is reported, not treated as an inventory result.
      skipped[#skipped + 1] = {
        archive = alias,
        memberId = memberId,
        code = Errors.is(result) and result.code or "LUA_ERROR",
        message = Errors.is(result) and result.message or tostring(result),
      }
    end
  end
  return out, skipped
end

local function landModels(narc, memberId)
  local land = assert(LandData.decode(assert(narc:readMember(memberId)), { alias = "land_data", memberId = memberId }))
  local file =
    assert(Nsbmd.decode(land.mapModelBytes, { alias = "land_data", memberId = memberId, section = "map-model" }))
  return file.models
end

local function buildModels(alias)
  return function(narc, memberId)
    local file = assert(Nsbmd.decode(assert(narc:readMember(memberId)), { alias = alias, memberId = memberId }))
    return file.models
  end
end

-- Scan every terrain and building model in the ROM. Returns
-- { entries, skipped } with entries in archive/member/model order.
function SbcInventory.scan(romFs)
  local entries, skipped = {}, {}
  local sources = {
    { alias = "land_data", modelsOf = landModels },
    { alias = "exterior_build_models", modelsOf = buildModels("exterior_build_models") },
    { alias = "interior_build_models", modelsOf = buildModels("interior_build_models") },
  }
  for _, source in ipairs(sources) do
    local got, missed = decodeMembers(romFs, source.alias, source.modelsOf)
    for _, e in ipairs(got) do
      entries[#entries + 1] = e
    end
    for _, s in ipairs(missed) do
      skipped[#skipped + 1] = s
    end
  end
  return { entries = entries, skipped = skipped }
end

-- ---- reporting ----

local function identity(entry)
  return string.format("%s:%d %s", entry.archive, entry.memberId, entry.modelName)
end

local function sortedPairs(map)
  local keys = {}
  for k in pairs(map) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

-- Deterministic, payload-free summary lines.
function SbcInventory.lines(report)
  local lines = {}
  local function add(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
  end

  local ruleCounts, ruleExamples = {}, {}
  local commandTotals, commandOwners = {}, {}
  local billboardWithRestore, billboardTotal = {}, 0
  local flagged = {}
  local plain = 0

  for _, e in ipairs(report.entries) do
    local rule = e.scalingRuleName .. "(" .. e.scalingRule .. ")"
    ruleCounts[rule] = (ruleCounts[rule] or 0) + 1
    if e.scalingRule ~= 0 then
      ruleExamples[rule] = ruleExamples[rule] or {}
      table.insert(ruleExamples[rule], identity(e))
    end
    for key, n in pairs(e.commands) do
      if key ~= "NODEDESC/0" then -- the ordinary joint; only variants are notable
        commandTotals[key] = (commandTotals[key] or 0) + n
        commandOwners[key] = commandOwners[key] or {}
        if #commandOwners[key] < 12 then
          table.insert(commandOwners[key], identity(e))
        end
      end
    end
    if #e.nodedescFlagBytes > 0 then
      local parts = {}
      for _, f in ipairs(e.nodedescFlagBytes) do
        parts[#parts + 1] = string.format("0x%02X", f)
      end
      table.insert(flagged, identity(e) .. " flags=" .. table.concat(parts, ","))
    end
    for _, shp in ipairs(e.billboardShapes) do
      billboardTotal = billboardTotal + 1
      if shp.usesMatrixRestore then
        table.insert(billboardWithRestore, identity(e) .. " shape " .. shp.shapeIndex .. " " .. tostring(shp.shapeName))
      end
    end
    if SbcInventory.isPlain(e) then
      plain = plain + 1
    end
  end

  add("sbc-inventory\tmodels\t%d", #report.entries)
  add("sbc-inventory\tplain-joint-models\t%d", plain)
  for _, rule in ipairs(sortedPairs(ruleCounts)) do
    add("sbc-inventory\tscaling-rule\t%s\t%d", rule, ruleCounts[rule])
    for _, id in ipairs(ruleExamples[rule] or {}) do
      add("sbc-inventory\tscaling-rule-model\t%s\t%s", rule, id)
    end
  end
  for _, key in ipairs(sortedPairs(commandTotals)) do
    add("sbc-inventory\tcommand\t%s\t%d", key, commandTotals[key])
    for _, id in ipairs(commandOwners[key]) do
      add("sbc-inventory\tcommand-model\t%s\t%s", key, id)
    end
  end
  for _, line in ipairs(flagged) do
    add("sbc-inventory\tnodedesc-flags\t%s", line)
  end
  add("sbc-inventory\tbillboard-shapes\t%d", billboardTotal)
  add("sbc-inventory\tbillboard-shapes-with-matrix-restore\t%d", #billboardWithRestore)
  for _, line in ipairs(billboardWithRestore) do
    add("sbc-inventory\tbillboard-matrix-restore\t%s", line)
  end
  for _, s in ipairs(report.skipped) do
    add("sbc-inventory\tskipped\t%s:%d\t%s\t%s", s.archive, s.memberId, s.code, s.message)
  end
  return lines
end

return SbcInventory
