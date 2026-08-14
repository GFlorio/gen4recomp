-- Test-only fixture: bounded control-flow scan of SSEQ bytecode for the
-- audio inventory. Not a decoder: it walks instruction boundaries
-- using the NitroSDK command layout (snd_seq.c / mml.h: notes 0x00-0x7F with
-- velocity + varlen duration; 0x80-0x8F varlen; 0x93 u8+u24, 0x94/0x95 u24;
-- 0xA0/0xA1/0xA2 prefixes; 0xB0-0xBF varNo+s16; 0xC0-0xDF u8; 0xE0-0xEF u16;
-- 0xF0-0xFF none) and follows control flow to a fixpoint so every reachable
-- instruction is inventoried and every jump/call target must land on an
-- instruction boundary. Every read is bounded by the file; anything else is
-- recorded as an anomaly instead of guessed.
--
-- Scan result: { census = {["XX:mode"]=count}, boundaries = {[offset]=true},
--   targets = { {at=, opcode=, target=}, ... }, anomalies = { {kind=, offset=} } }
-- where mode is "plain", "random", or "variable".

local SseqScan = {}

SseqScan.PREFIX_RANDOM = 0xA0
SseqScan.PREFIX_VARIABLE = 0xA1
SseqScan.PREFIX_IF = 0xA2

local function u8(data, pos)
  return string.byte(data, pos + 1)
end

local function u24(data, pos)
  local b1, b2, b3 = string.byte(data, pos + 1, pos + 3)
  return b1 + b2 * 256 + b3 * 65536
end

-- Variable-length value; returns value, nextPos or nil, nextPos when the
-- value runs past the end of the file.
local function readVarlen(data, pos, endPos)
  local value = 0
  while pos < endPos do
    local byte = u8(data, pos)
    pos = pos + 1
    value = value * 128 + byte % 128
    if byte < 128 then
      return value, pos
    end
  end
  return nil, pos
end

---@param data string
---@return table
function SseqScan.scan(data)
  local census = {}
  local boundaries = {}
  local targets = {}
  local anomalies = {}
  local endPos = #data

  local function anomaly(kind, offset)
    anomalies[#anomalies + 1] = { kind = kind, offset = offset }
  end

  if endPos < 0x1C then
    anomaly("short-header", 0)
    return { census = census, boundaries = boundaries, targets = targets, anomalies = anomalies }
  end

  local dataOffset = u24(data, 0x18) -- stored as u32; bounds check below
  if dataOffset < 0x1C or dataOffset > endPos then
    anomaly("data-offset-past-end", dataOffset)
    return { census = census, boundaries = boundaries, targets = targets, anomalies = anomalies }
  end

  -- Entry points: track 0 (after the optional FE track-mask header, whose
  -- 0x93 open-track records are the first commands of track 0's program) and
  -- every open-track target. Jumps and calls discovered while walking are
  -- added as entry points too, so the walk reaches a fixpoint over the whole
  -- reachable program.
  local queue = {}
  local pos = dataOffset
  if pos < endPos and u8(data, pos) == 0xFE then
    pos = pos + 3
    if pos > endPos then
      anomaly("track-mask-past-end", dataOffset)
      return { census = census, boundaries = boundaries, targets = targets, anomalies = anomalies }
    end
    while pos + 5 <= endPos and u8(data, pos) == 0x93 do
      queue[#queue + 1] = u24(data, pos + 2)
      pos = pos + 5
    end
  end
  queue[#queue + 1] = pos

  local seen = {}
  while #queue > 0 do
    local start = table.remove(queue)
    if seen[start] then
      -- already fully walked: a loop or a shared subroutine
    elseif start >= endPos then
      anomaly("target-past-end", start)
    else
      pos = start
      while pos < endPos and not seen[pos] do
        seen[pos] = true
        boundaries[pos] = true
        local cmd = u8(data, pos)
        pos = pos + 1
        local mode = "plain"
        if cmd == SseqScan.PREFIX_IF or cmd == SseqScan.PREFIX_RANDOM or cmd == SseqScan.PREFIX_VARIABLE then
          if pos >= endPos then
            anomaly("prefix-past-end", pos - 1)
            break
          end
          cmd = u8(data, pos)
          pos = pos + 1
          if cmd == SseqScan.PREFIX_RANDOM then
            mode = "random"
          elseif cmd == SseqScan.PREFIX_VARIABLE then
            mode = "variable"
          end
        end
        local key = string.format("%02X:%s", cmd, mode)
        census[key] = (census[key] or 0) + 1

        if cmd == 0xFF or cmd == 0xFD then
          break -- track end / return to caller
        end

        if cmd < 0x80 then
          -- note: velocity byte, then the argument
          pos = pos + 1
          if mode == "random" then
            pos = pos + 4
          elseif mode == "variable" then
            pos = pos + 1
          else
            local value, nextPos = readVarlen(data, pos, endPos)
            if value == nil then
              anomaly("varlen-past-end", pos - 1)
              break
            end
            pos = nextPos
          end
        elseif cmd <= 0x8F then
          if mode == "random" then
            pos = pos + 4
          elseif mode == "variable" then
            pos = pos + 1
          else
            local value, nextPos = readVarlen(data, pos, endPos)
            if value == nil then
              anomaly("varlen-past-end", pos - 1)
              break
            end
            pos = nextPos
          end
        elseif cmd <= 0x9F then
          if cmd == 0x93 then
            if pos + 4 > endPos then
              anomaly("open-track-past-end", pos - 1)
              break
            end
            queue[#queue + 1] = u24(data, pos + 1)
            pos = pos + 4
          elseif cmd == 0x94 or cmd == 0x95 then
            if pos + 3 > endPos then
              anomaly("target-operand-past-end", pos - 1)
              break
            end
            local target = u24(data, pos)
            targets[#targets + 1] = { at = pos - 1, opcode = cmd, target = target }
            pos = pos + 3
            queue[#queue + 1] = target
            if cmd == 0x94 then
              break -- jump: this path continues at the target
            end
          end
        elseif cmd <= 0xAF then
          -- 0xA0-0xA2 consumed as prefixes above; 0xA3-0xAF are ignored
        elseif cmd <= 0xBF then
          pos = pos + 1
          if mode == "random" then
            pos = pos + 4
          elseif mode == "variable" then
            pos = pos + 1
          else
            pos = pos + 2
          end
        elseif cmd <= 0xDF then
          if mode == "random" then
            pos = pos + 4
          else
            pos = pos + 1
          end
        elseif cmd <= 0xEF then
          if mode == "random" then
            pos = pos + 4
          else
            pos = pos + 2
          end
        end

        if pos > endPos then
          anomaly("operand-past-end", pos - 1)
          break
        end
      end
    end
  end

  return { census = census, boundaries = boundaries, targets = targets, anomalies = anomalies }
end

return SseqScan
