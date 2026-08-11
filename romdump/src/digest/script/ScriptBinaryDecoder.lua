-- Binary scr_seq member decoder : decodes a retail scr_seq
-- NARC member straight from the ROM dump. The retail member layout is a table
-- of relative u32 entries (entry[i] = scriptOffset - entryPos - 4) followed by
-- a u16 0xFD13 (SCRDEF_END) sentinel, with script bodies and movement blocks
-- interleaved at arbitrary four-aligned offsets. Branch/Call/ApplyMovement
-- operands are relative word offsets from the end of the instruction; message
-- operands are indices into the map's message bank (resolved by the compiler
-- through the pinned member-bank map). Header members (scriptHeaderBank) carry
-- no script table and return nil. Pure domain module: no love dependency.

local RawIr = require("romdump.src.digest.script.RawIr")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local MovementCommands = require("data.reference.hgss.movement_commands")

local ScriptBinaryDecoder = {}

local SCRDEF_END = 0xFD13
local MOVEMENT_END = 254

-- Opcodes whose word operand is a relative target from the end of the
-- instruction (operand index, 1-based).
local RELATIVE_OPERANDS = {
  [22] = 1, -- GoTo
  [23] = 2, -- ObjectGoTo
  [24] = 2, -- BGGoTo
  [25] = 2, -- DirectionGoTo
  [26] = 1, -- Call
  [28] = 2, -- GoToIf
  [29] = 2, -- CallIf
  [94] = 2, -- ApplyMovement (movement-block offset)
}

-- Message-printing opcodes: operand indices carrying a message index in the
-- map's bank (the bank itself never appears in the member).
local MESSAGE_OPERANDS = {
  [44] = { 1 }, -- NonNPCMsg
  [45] = { 1 }, -- NPCMsg
  [132] = { 1, 2 }, -- GenderMsgBox
}

-- Message-or-variable operands: ScrCmd_NonNPCMsgVar/NPCMsgVar read the
-- operand as a message id directly when it lies below VAR_BASE (0x4000,
-- GetVarPointer returns NULL there and VarGet yields the operand itself) and
-- as a variable reference otherwise.
local MESSAGE_VALUE_OPERANDS = {
  [46] = { 1 }, -- NonNPCMsgVar
  [47] = { 1 }, -- NPCMsgVar
}

-- Sound-sequence operands (SEQ_* names from sndseq.h).
local SOUND_OPERANDS = {
  [73] = { 1 }, -- PlaySE
  [74] = { 1 }, -- StopSE
  [75] = { 1 }, -- WaitSE
  [78] = { 1 }, -- PlayFanfare
  [80] = { 1 }, -- PlayBGM
  [81] = { 1 }, -- StopBGM
  [87] = { 1 }, -- TempBGM
}

-- Flag operands (FLAG_* names from flags.h).
local FLAG_OPERANDS = {
  [30] = { 1 }, -- SetFlag
  [31] = { 1 }, -- ClearFlag
  [32] = { 1 }, -- CheckFlag
}

-- Variable ranges (vars.h): VARS [0x4000, 0x4400), SPECIAL_VARS [0x8000,
-- 0x8100). Operand numbers inside a range are variable references and are
-- named through the pinned vars catalog.
local VAR_RANGES = {
  { start = 0x4000, finish = 0x4400 },
  { start = 0x8000, finish = 0x8100 },
}

-- The warp map operand (maps.lua mapCode names).
local MAP_OPERANDS = {
  [176] = { 1 }, -- Warp
}

-- Respawn operands (SPAWN_* names from spawns.h).
local SPAWN_OPERANDS = {
  [280] = { 1 }, -- SetSpawn
}

---@param bytes string
---@return table reader
local function reader(bytes)
  return {
    bytes = bytes,
    pos = 0,
    u16 = function(self)
      if self.pos + 1 >= #self.bytes then
        return nil
      end
      local value = self.bytes:byte(self.pos + 1) + self.bytes:byte(self.pos + 2) * 256
      self.pos = self.pos + 2
      return value
    end,
    u32 = function(self)
      local lo = self:u16()
      local hi = self:u16()
      if lo == nil or hi == nil then
        return nil
      end
      return lo + hi * 65536
    end,
  }
end

-- Scan the entry table: `{ pos, entry, label }` per script in index order.
-- Returns an empty list when the member carries no script table (a header
-- member, or garbage).
---@param bytes string
---@return table[] entries
local function scanEntries(bytes)
  local entries = {}
  local pos = 0
  while pos + 3 < #bytes do
    local low = bytes:byte(pos + 1) + bytes:byte(pos + 2) * 256
    if low == SCRDEF_END then
      break
    end
    local entry = bytes:byte(pos + 1)
      + bytes:byte(pos + 2) * 256
      + bytes:byte(pos + 3) * 65536
      + bytes:byte(pos + 4) * 16777216
    local label = pos + 4 + entry
    -- A real entry points forward into the script region, never back into
    -- the table itself.
    if label < pos + 4 or label + 1 > #bytes then
      break
    end
    entries[#entries + 1] = { pos = pos, entry = entry, label = label }
    pos = pos + 4
  end
  return entries
end

-- Decode one movement block at `offset`: u16 code + u16 args per action,
-- terminated by MOVEMENT_STEP_END (254) plus its zero arg.
---@param bytes string
---@param offset integer
---@return table|nil block { offset, actions, terminated, size }
local function decodeMovement(bytes, offset)
  local actions = {}
  local cursor = offset
  local terminated = false
  while cursor + 1 < #bytes do
    local code = bytes:byte(cursor + 1) + bytes:byte(cursor + 2) * 256
    if code == MOVEMENT_END then
      cursor = cursor + 4
      terminated = true
      break
    end
    local entry = MovementCommands.byCode[code]
    if entry == nil then
      -- Unknown movement code: stop the block (the verifier flags it); the
      -- walk still skips the two bytes read so far.
      cursor = cursor + 2
      break
    end
    local size = 2 + 2 * entry.args
    local count = bytes:byte(cursor + 3) or 0
    if entry.args >= 1 and cursor + 4 <= #bytes then
      count = count + bytes:byte(cursor + 4) * 256
    end
    actions[#actions + 1] = RawIr.movementAction(cursor, code, entry.name, count)
    cursor = cursor + size
  end
  return {
    offset = offset,
    actions = actions,
    terminated = terminated,
    size = cursor - offset,
  }
end

-- Resolve a message operand to its bank-qualified symbol; the bank comes
-- from the pinned member-bank map (the member carries indices only).
---@param index number
---@param msgBank integer|nil
---@return string
local function messageSymbol(index, msgBank)
  return string.format("msg_%04d_x_%05d", msgBank or 0, index)
end

-- Resolve a relative word operand (label-.-4 semantics: signed offset from
-- the end of the instruction) to an absolute member offset.
---@param ins table
---@param operand table
---@return integer
local function resolveRelative(ins, operand)
  local raw = operand.raw
  if raw >= 0x80000000 then
    raw = raw - 0x100000000
  end
  return ins.offset + ins.size + raw
end

-- Decode one member's scripts. `opts.msgBank` names the map message bank for
-- message operands. Returns nil for header members (no script table).
---@param bytes string
---@param member integer
---@param sourcePath string
---@param opts table { msgBank: integer|nil }
---@return table|nil memberIr
function ScriptBinaryDecoder.parseMember(bytes, member, sourcePath, opts)
  local entries = scanEntries(bytes)
  if #entries == 0 then
    return nil
  end
  local out = RawIr.member(member, sourcePath, nil)
  local scriptStarts = {}
  for index, entry in ipairs(entries) do
    scriptStarts[entry.label] = index - 1
  end

  -- Movement blocks discovered through ApplyMovement operands; the walk
  -- skips them, so a block interleaved inside a script's byte range never
  -- decodes as phantom instructions. Newly registered blocks trigger a
  -- re-walk until no block appears inside an already-walked region.
  local movements = {}
  local registered = {}
  local function registerMovement(offset)
    if offset >= 0 and offset + 1 <= #bytes and registered[offset] == nil then
      registered[offset] = true
      return true
    end
    return false
  end

  -- Dead movement data (no ApplyMovement reference) is recognized by shape
  -- when the walk would otherwise stall on it: a clean terminated movement
  -- decode starting within a few bytes of the cursor. Script opcodes overlap
  -- movement codes, so the check only runs where the walk has no other
  -- justification (post-terminator, unreferenced cursors).
  local function movementShapeAt(cursor)
    for back = 0, 3 do
      local candidate = cursor - back
      if candidate >= 0 then
        local block = decodeMovement(bytes, candidate)
        if block ~= nil and block.terminated and block.size <= 64 then
          return candidate, block
        end
      end
    end
    return nil
  end

  local function decodeScripts(justified)
    local scripts = {}
    for scriptIndex, entry in ipairs(entries) do
      local script = {
        label = ("scr_seq_%04d_%03d"):format(member, scriptIndex - 1),
        index = scriptIndex - 1,
        instructions = {},
      }
      local cursor = entry.label
      local terminated = false
      local tailRun = false
      while cursor + 1 < #bytes do
        local owner = scriptStarts[cursor]
        if owner ~= nil and owner ~= scriptIndex - 1 then
          break
        end
        local block = movements[cursor]
        if block ~= nil then
          cursor = cursor + block.size
          tailRun = false
        else
          -- A cursor that landed inside a registered movement block's span
          -- (alignment padding between a script terminator and the block),
          -- or whose two-byte opcode read would overlap the block start,
          -- skips the whole block instead of drifting through its bytes.
          local spanning = nil
          for offset, candidate in pairs(movements) do
            if (cursor >= offset and cursor < offset + candidate.size) or (cursor < offset and cursor + 2 > offset) then
              spanning = candidate
              break
            end
          end
          if spanning ~= nil then
            cursor = cursor + (spanning.offset + spanning.size - cursor)
            tailRun = false
          elseif terminated and not tailRun and justified[cursor] ~= true then
            -- Past the script terminator, outside a shared-subroutine run,
            -- only referenced targets and movement-shaped data decode. A
            -- referenced target within the next few bytes is alignment
            -- padding before a shared tail; the movement shape wins for
            -- unreferenced (dead) blocks; anything else ends the walk
            -- silently.
            local skipped = false
            for lookahead = 1, 4 do
              if justified[cursor + lookahead] == true then
                cursor = cursor + lookahead
                tailRun = true
                skipped = true
                break
              end
            end
            if not skipped then
              local candidate, shapeBlock = movementShapeAt(cursor)
              if candidate ~= nil then
                local shape = shapeBlock --[[@as { offset: integer, actions: table, terminated: boolean, size: integer }]]
                movements[candidate] = shape
                cursor = candidate + shape.size
              else
                break
              end
            end
          else
            if terminated and not tailRun and justified[cursor] == true then
              tailRun = true
            end
            local opcode = bytes:byte(cursor + 1) + bytes:byte(cursor + 2) * 256
            local widths = CommandCatalog.widths(opcode)
            if widths == nil then
              -- Unknown opcode: the region may be dead movement data entered
              -- before any terminator; the movement shape wins when it
              -- decodes cleanly, otherwise the walk stops with a note.
              local candidate, shapeBlock = movementShapeAt(cursor)
              if candidate ~= nil then
                local shape = shapeBlock --[[@as { offset: integer, actions: table, terminated: boolean, size: integer }]]
                movements[candidate] = shape
                cursor = candidate + shape.size
                tailRun = false
              else
                script.decodeNote = { offset = cursor, opcode = opcode }
                break
              end
            else
              local operands = {}
              local size = 2
              local argCursor = cursor + 2
              local truncated = false
              local function readOperand(width)
                if argCursor + width > #bytes then
                  truncated = true
                  return
                end
                local value
                if width == 1 then
                  value = bytes:byte(argCursor + 1)
                elseif width == 2 then
                  value = bytes:byte(argCursor + 1) + bytes:byte(argCursor + 2) * 256
                else
                  value = bytes:byte(argCursor + 1)
                    + bytes:byte(argCursor + 2) * 256
                    + bytes:byte(argCursor + 3) * 65536
                    + bytes:byte(argCursor + 4) * 16777216
                end
                operands[#operands + 1] = { raw = value, width = width }
                argCursor = argCursor + width
                size = size + width
              end
              if truncated then
                -- A truncated trailing instruction: stop the walk and record it.
                script.decodeNote = { offset = cursor, opcode = opcode }
                break
              end
              for _, width in ipairs(widths) do
                readOperand(width)
              end
              -- Arg-dependent widths (MysteryGift and the flag-action variants):
              -- the extra operands depend on a decoded base operand value.
              local extraWidths = CommandCatalog.variantExtraWidths(opcode, operands)
              if extraWidths ~= nil then
                for _, width in ipairs(extraWidths) do
                  readOperand(width)
                end
              end
              if truncated then
                script.decodeNote = { offset = cursor, opcode = opcode }
                break
              end
              if opcode == 94 then
                -- ApplyMovement arg1: relative movement-block offset.
                local raw = operands[2] and operands[2].raw
                if type(raw) == "number" then
                  if raw >= 0x80000000 then
                    raw = raw - 0x100000000
                  end
                  local target = cursor + size + raw
                  if registerMovement(target) then
                    local block = decodeMovement(bytes, target)
                    if block ~= nil then
                      movements[target] = block
                    end
                  end
                end
              end
              local relIndex = RELATIVE_OPERANDS[opcode]
              if relIndex ~= nil and operands[relIndex] ~= nil and type(operands[relIndex].raw) == "number" then
                local raw = operands[relIndex].raw
                if raw >= 0x80000000 then
                  raw = raw - 0x100000000
                end
                justified[cursor + size + raw] = true
              end
              script.instructions[#script.instructions + 1] =
                RawIr.instruction(cursor, opcode, CommandCatalog.name(opcode), operands, size, nil)
              cursor = cursor + size
              if opcode == 2 or opcode == 21 or opcode == 27 then
                -- A shared-subroutine run ends at its own terminator; the next
                -- region must justify itself anew.
                terminated = true
                tailRun = false
              end
            end
          end
        end
      end
      scripts[scriptIndex] = script
    end
    return scripts
  end

  -- Fixpoint: keep walking until neither new movement blocks nor new branch
  -- targets are registered (a target justifies a shared-subroutine tail in
  -- the next pass).
  local scripts
  local justified = {}
  local changed = true
  while changed do
    changed = false
    local before = 0
    for _ in pairs(registered) do
      before = before + 1
    end
    local targetsBefore = 0
    for _ in pairs(justified) do
      targetsBefore = targetsBefore + 1
    end
    scripts = decodeScripts(justified)
    local after = 0
    for _ in pairs(registered) do
      after = after + 1
    end
    local targetsAfter = 0
    for _ in pairs(justified) do
      targetsAfter = targetsAfter + 1
    end
    if after > before or targetsAfter > targetsBefore then
      changed = true
    end
  end

  -- Attach labels at every branch target and resolve relative operands to
  -- label names (decomp-style `_XXXX`), so lowering, structuring, and the
  -- verifier treat binary members exactly like assembly listings.
  local targets = {}
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local relIndex = RELATIVE_OPERANDS[ins.opcode]
      if relIndex ~= nil then
        local operand = ins.operands[relIndex]
        if operand ~= nil and type(operand.raw) == "number" then
          targets[resolveRelative(ins, operand)] = true
        end
      end
    end
  end
  local labelAt = {}
  for target in pairs(targets) do
    labelAt[target] = ("_%04X"):format(target)
  end
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local label = labelAt[ins.offset]
      if label ~= nil then
        ins.label = label
      end
    end
  end
  for _, script in ipairs(scripts) do
    for _, ins in ipairs(script.instructions) do
      local relIndex = RELATIVE_OPERANDS[ins.opcode]
      if relIndex ~= nil then
        local operand = ins.operands[relIndex]
        local raw = operand and operand.raw
        if type(raw) == "number" then
          local target = resolveRelative(ins, operand)
          local label = labelAt[target]
          if label ~= nil then
            operand.raw = label
          else
            local owner = scriptStarts[target]
            if owner ~= nil then
              operand.raw = ("scr_seq_%04d_%03d"):format(member, owner)
            end
          end
        end
      end
    end
  end

  -- Message operands: bank-qualified symbols.
  if opts.msgBank ~= nil then
    for _, script in ipairs(scripts) do
      for _, ins in ipairs(script.instructions) do
        local indices = MESSAGE_OPERANDS[ins.opcode]
        if indices ~= nil then
          for _, operandIndex in ipairs(indices) do
            local operand = ins.operands[operandIndex]
            if operand ~= nil then
              local raw = operand.raw
              if type(raw) == "number" then
                operand.raw = messageSymbol(raw, opts.msgBank)
              end
            end
          end
        end
        -- NonNPCMsgVar/NPCMsgVar: a direct message id below VAR_BASE, a
        -- variable reference otherwise (var resolution runs below). The
        -- direct id emits the resolvable message ref form (the varRef
        -- handlers pass strings through).
        local valueIndices = MESSAGE_VALUE_OPERANDS[ins.opcode]
        if valueIndices ~= nil then
          for _, operandIndex in ipairs(valueIndices) do
            local operand = ins.operands[operandIndex]
            if operand ~= nil and type(operand.raw) == "number" and operand.raw < 0x4000 then
              operand.raw = string.format("msg.hgss.%04d.%05d", opts.msgBank, operand.raw)
            end
          end
        end
      end
    end
  end

  -- Operand names: sounds, flags, vars, and warp maps resolve through the
  -- pinned constant catalogs; unknown ids get deterministic mechanical names
  -- so every generated step stays symbolic. Var-range numbers resolve for
  -- every operand (the lowering's varRef treats them as variable
  -- references), matching the assembly listing behavior.
  if opts.catalog ~= nil then
    local sounds = opts.catalog.sounds
    local flags = opts.catalog.flags
    local vars = opts.catalog.vars
    local maps = opts.catalog.maps
    local spawns = opts.catalog.spawns
    local function nameFor(value, catalog, prefix)
      local name = catalog[value]
      if name ~= nil then
        return name
      end
      return ("%s_0x%04X"):format(prefix, value)
    end
    for _, script in ipairs(scripts) do
      for _, ins in ipairs(script.instructions) do
        for operandIndex, operand in ipairs(ins.operands) do
          local raw = operand.raw
          if type(raw) == "number" then
            local named = false
            if sounds ~= nil and SOUND_OPERANDS[ins.opcode] and SOUND_OPERANDS[ins.opcode][operandIndex] then
              operand.raw = nameFor(raw, sounds, "SEQ")
              named = true
            elseif flags ~= nil and FLAG_OPERANDS[ins.opcode] and FLAG_OPERANDS[ins.opcode][operandIndex] then
              operand.raw = nameFor(raw, flags, "FLAG")
              named = true
            elseif
              maps ~= nil
              and MAP_OPERANDS[ins.opcode]
              and MAP_OPERANDS[ins.opcode][operandIndex]
              and maps[raw] ~= nil
            then
              operand.raw = maps[raw].mapCode
              named = true
            elseif spawns ~= nil and SPAWN_OPERANDS[ins.opcode] and SPAWN_OPERANDS[ins.opcode][operandIndex] then
              operand.raw = nameFor(raw, spawns, "SPAWN")
              named = true
            end
            if not named and vars ~= nil then
              for _, range in ipairs(VAR_RANGES) do
                if raw >= range.start and raw < range.finish then
                  operand.raw = nameFor(raw, vars, "VAR")
                  break
                end
              end
            end
          end
        end
      end
    end
  end

  for index, script in ipairs(scripts) do
    -- A table entry that lands on a shared-subroutine body (returns without
    -- any call: the callers live in other scripts) is a prelude-shaped
    -- library; the verifier's prelude tolerance applies to its balance.
    local hasCall = false
    local hasReturn = false
    for _, ins in ipairs(script.instructions) do
      if ins.opcode == 26 or ins.opcode == 29 then
        hasCall = true
      end
      if ins.opcode == 27 then
        hasReturn = true
      end
    end
    if hasReturn and not hasCall then
      script.prelude = true
    end
    out.scripts[script.index] = script
  end
  for offset, block in pairs(movements) do
    out.movements[offset] = block
  end
  return out
end

-- Decode every script member of the scr_seq archive. Header members return
-- nil and are reported as `skipped`; script members keep their decode notes.
---@param archive table Narc-shaped
---@param banks table<integer, integer>
---@param sourcePath string
---@param catalog table|nil { sounds, flags, vars, maps }
---@return table memberIrs table<integer, table|nil>
function ScriptBinaryDecoder.decodeArchive(archive, banks, sourcePath, catalog)
  local memberIrs = {}
  for member = 0, archive:memberCount() - 1 do
    local bytes = archive:readMember(member)
    local ok, memberIr =
      pcall(ScriptBinaryDecoder.parseMember, bytes, member, sourcePath, { msgBank = banks[member], catalog = catalog })
    if not ok then
      error(memberIr, 0)
    end
    memberIrs[member] = memberIr
  end
  return memberIrs
end

return ScriptBinaryDecoder
