-- Coverage report : aggregates translation outcomes into
-- the JSON fields of the section, plus a deterministic Markdown summary.
-- Every opcode seen anywhere appears with its status (supported/unsupported)
-- and occurrence counts; scripts are listed with their source identity,
-- public id, and status. A corpus-level record aggregates per-member
-- records. Pure domain module: no love dependency.

local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")

local Coverage = {}

-- Build the JSON-shaped coverage record for one member.
---@param memberIr table
---@param results table script index -> { script, lowered, report, resource }
---@param source table { repository, romSha1 }
---@return table record
function Coverage.record(memberIr, results, source)
  local totals = {
    members = 1,
    scripts = 0,
    reachableInstructions = 0,
    supportedInstructions = 0,
    unsupportedInstructions = 0,
    malformedInstructions = 0,
  }
  local opcodes = {}
  local scripts = {}
  -- Occurrence counts from the raw instruction streams (every opcode seen,
  -- whether supported, unsupported, or malformed) plus the count of
  -- instructions that had to lower to an explicit unsupported node. The
  -- per-opcode status is derived from those counts, so an opcode that is
  -- translated in some scripts and rejected in others reports `mixed`.
  for _, script in pairs(memberIr.scripts) do
    local seenPerScript = {}
    for _, ins in ipairs(script.instructions) do
      local entry = opcodes[ins.opcode]
      if entry == nil then
        entry = {
          name = CommandCatalog.name(ins.opcode),
          status = "supported",
          occurrences = 0,
          scripts = 0,
          unsupportedOccurrences = 0,
        }
        opcodes[ins.opcode] = entry
      end
      entry.occurrences = entry.occurrences + 1
      if not seenPerScript[ins.opcode] then
        seenPerScript[ins.opcode] = true
        entry.scripts = entry.scripts + 1
      end
    end
  end
  local function statusOf(entry)
    if entry.unsupportedOccurrences == 0 then
      return "supported"
    end
    if entry.unsupportedOccurrences == entry.occurrences then
      return "unsupported"
    end
    return "mixed"
  end
  for index, result in pairs(results) do
    totals.scripts = totals.scripts + 1
    totals.reachableInstructions = totals.reachableInstructions + result.report.reachable
    totals.unsupportedInstructions = totals.unsupportedInstructions + result.report.unsupportedCount
    totals.supportedInstructions = totals.supportedInstructions
      + (result.report.reachable - result.report.unsupportedCount)
    local status = "complete"
    if result.report.unsupportedCount > 0 then
      status = "partial"
    end
    if not result.report.ok then
      status = "malformed"
    end
    local scriptEntry = {
      sourceId = string.format("hgss.scr_seq.%04d.%03d", memberIr.member, index),
      publicId = result.resource and result.resource.id or nil,
      status = status,
      unsupported = {},
    }
    for _, item in ipairs(result.report.unsupported) do
      scriptEntry.unsupported[#scriptEntry.unsupported + 1] = {
        command = item.command,
        originalName = item.originalName,
        sourceOffset = item.sourceOffset,
      }
      local opcode = item.command
      local entry = opcodes[opcode]
      if entry == nil then
        entry = {
          name = CommandCatalog.name(opcode),
          status = "supported",
          occurrences = 0,
          scripts = 0,
          unsupportedOccurrences = 0,
        }
        opcodes[opcode] = entry
      end
      -- The raw-stream walk already counted this instruction; an explicit
      -- unsupported node marks this occurrence unsupported.
      entry.unsupportedOccurrences = entry.unsupportedOccurrences + 1
    end
    scripts[#scripts + 1] = scriptEntry
  end
  for _, entry in pairs(opcodes) do
    entry.status = statusOf(entry)
  end
  table.sort(scripts, function(a, b)
    return a.sourceId < b.sourceId
  end)
  return {
    source = source,
    totals = totals,
    opcodes = opcodes,
    scripts = scripts,
  }
end

-- Aggregate per-member records into one corpus record.
---@param records table[]
---@return table record
function Coverage.aggregate(records)
  local totals = {
    members = 0,
    scripts = 0,
    reachableInstructions = 0,
    supportedInstructions = 0,
    unsupportedInstructions = 0,
    malformedInstructions = 0,
  }
  local opcodes = {}
  local scripts = {}
  local function statusOf(entry)
    if entry.unsupportedOccurrences == 0 then
      return "supported"
    end
    if entry.unsupportedOccurrences == entry.occurrences then
      return "unsupported"
    end
    return "mixed"
  end
  for _, record in ipairs(records) do
    totals.members = totals.members + record.totals.members
    totals.scripts = totals.scripts + record.totals.scripts
    totals.reachableInstructions = totals.reachableInstructions + record.totals.reachableInstructions
    totals.supportedInstructions = totals.supportedInstructions + record.totals.supportedInstructions
    totals.unsupportedInstructions = totals.unsupportedInstructions + record.totals.unsupportedInstructions
    totals.malformedInstructions = totals.malformedInstructions + record.totals.malformedInstructions
    for opcode, entry in pairs(record.opcodes) do
      local target = opcodes[opcode]
      if target == nil then
        target = { name = entry.name, status = "supported", occurrences = 0, scripts = 0, unsupportedOccurrences = 0 }
        opcodes[opcode] = target
      end
      target.occurrences = target.occurrences + entry.occurrences
      target.scripts = target.scripts + entry.scripts
      target.unsupportedOccurrences = target.unsupportedOccurrences + entry.unsupportedOccurrences
    end
    for _, script in ipairs(record.scripts) do
      scripts[#scripts + 1] = script
    end
  end
  for _, entry in pairs(opcodes) do
    entry.status = statusOf(entry)
  end
  table.sort(scripts, function(a, b)
    return a.sourceId < b.sourceId
  end)
  local source = records[1] and records[1].source or { repository = "", romSha1 = "" }
  return { source = source, totals = totals, opcodes = opcodes, scripts = scripts }
end

-- Deterministic Markdown summary.
---@param record table
---@return string
function Coverage.markdown(record)
  local lines = {}
  lines[#lines + 1] = "# HGSS script coverage"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Source: " .. record.source.repository .. "@" .. record.source.romSha1
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Metric | Count |"
  lines[#lines + 1] = "|---|---:|"
  lines[#lines + 1] = "| Members | " .. record.totals.members .. " |"
  lines[#lines + 1] = "| Scripts | " .. record.totals.scripts .. " |"
  lines[#lines + 1] = "| Reachable instructions | " .. record.totals.reachableInstructions .. " |"
  lines[#lines + 1] = "| Supported instructions | " .. record.totals.supportedInstructions .. " |"
  lines[#lines + 1] = "| Unsupported instructions | " .. record.totals.unsupportedInstructions .. " |"
  lines[#lines + 1] = "| Malformed instructions | " .. record.totals.malformedInstructions .. " |"
  lines[#lines + 1] = ""
  local complete = 0
  local partial = 0
  local malformed = 0
  for _, script in ipairs(record.scripts) do
    if script.status == "complete" then
      complete = complete + 1
    elseif script.status == "malformed" then
      malformed = malformed + 1
    else
      partial = partial + 1
    end
  end
  lines[#lines + 1] = "| Scripts complete | " .. complete .. " |"
  lines[#lines + 1] = "| Scripts partial | " .. partial .. " |"
  lines[#lines + 1] = "| Scripts malformed | " .. malformed .. " |"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Opcodes"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Opcode | Name | Status | Occurrences | Scripts |"
  lines[#lines + 1] = "|---:|---|---|---:|---:|"
  local opcodes = {}
  for opcode, entry in pairs(record.opcodes) do
    opcodes[#opcodes + 1] = { opcode = opcode, entry = entry }
  end
  table.sort(opcodes, function(a, b)
    return a.opcode < b.opcode
  end)
  for _, item in ipairs(opcodes) do
    lines[#lines + 1] = "| "
      .. item.opcode
      .. " | "
      .. item.entry.name
      .. " | "
      .. item.entry.status
      .. " | "
      .. item.entry.occurrences
      .. " | "
      .. item.entry.scripts
      .. " |"
  end
  lines[#lines + 1] = ""
  local top = {}
  for _, item in ipairs(opcodes) do
    if item.entry.status == "unsupported" then
      top[#top + 1] = item
    end
  end
  table.sort(top, function(a, b)
    if a.entry.occurrences == b.entry.occurrences then
      return a.opcode < b.opcode
    end
    return a.entry.occurrences > b.entry.occurrences
  end)
  lines[#lines + 1] = "## Top unsupported opcodes"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Opcode | Name | Occurrences |"
  lines[#lines + 1] = "|---:|---|---:|"
  for i = 1, math.min(15, #top) do
    local item = top[i]
    lines[#lines + 1] = "| " .. item.opcode .. " | " .. item.entry.name .. " | " .. item.entry.occurrences .. " |"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Vertical slice"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| Script | Status |"
  lines[#lines + 1] = "|---|---|"
  local sliceIds = {
    "vanilla.hgss.scr_seq.0842.script_001",
    "vanilla.hgss.scr_seq.0843.script_009",
    "vanilla.hgss.scr_seq.0843.script_000",
  }
  for _, script in ipairs(record.scripts) do
    for _, wanted in ipairs(sliceIds) do
      if script.publicId == wanted then
        lines[#lines + 1] = "| " .. script.publicId .. " | " .. script.status .. " |"
      end
    end
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n") .. "\n"
end

return Coverage
