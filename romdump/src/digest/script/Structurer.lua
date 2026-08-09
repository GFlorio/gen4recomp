-- Control-flow structuring : turns the lowered item list
-- (linear items plus if_cond/goto/call_if control items) into structured
-- `if`/`else` blocks where provable, retaining labels and gotos otherwise.
-- The v1 algorithm peels the canonical conditional-skip pattern (a
-- conditional branch to a forward label whose fallthrough chain ends with an
-- unconditional goto to the region join); anything else falls back to
-- labels and gotos. Correctness beats readability. Pure domain module: no
-- love dependency.

local Structurer = {}

-- Negate a condition for the structured if (the fallthrough of a GoToIf
-- runs when the branch condition does not hold).
---@param condition table
---@return table
local function negate(condition)
  if condition.condition == "compare" then
    local flipped = { lt = "ge", ge = "lt", gt = "le", le = "gt", eq = "ne", ne = "eq" }
    local copy = {}
    for key, value in pairs(condition) do
      copy[key] = value
    end
    copy.operator = flipped[condition.operator] or condition.operator
    return copy
  elseif condition.condition == "flag" then
    local copy = {}
    for key, value in pairs(condition) do
      copy[key] = value
    end
    copy.expected = not condition.expected
    return copy
  elseif condition.condition == "not" then
    return condition.operand
  end
  return { condition = "not", operand = condition }
end

-- Collect the label positions in the item list (item index -> label name).
---@param items table[]
---@return table<string, integer>
local function labelPositions(items)
  local positions = {}
  for i, item in ipairs(items) do
    if item.op == "label" then
      positions[item.name] = i
    end
  end
  return positions
end

-- Build the per-item branch targets (after label resolution): index -> list
-- of target indices.
---@param items table[]
---@param positions table<string, integer>
---@return table<integer, integer[]>
local function edges(items, positions)
  local out = {}
  for i, item in ipairs(items) do
    local targets = {}
    if item.op == "if_cond" or item.op == "call_if" or item.op == "goto" then
      local target = positions[item.target]
      if target ~= nil then
        targets[#targets + 1] = target
      end
    end
    out[i] = targets
  end
  return out
end

-- Count every control item that targets each label. A conditional's boundary
-- label is consumed by the structured peel; when another control item also
-- targets that label (a jump into the middle of the candidate region), the
-- peel must not run and the label/goto fallback is retained instead (spec
-- section 32.6: ambiguous branch ownership).
---@param items table[]
---@param positions table<string, integer>
---@return table<string, integer>
local function labelRefCounts(items, positions)
  local counts = {}
  for i, item in ipairs(items) do
    if item.op == "if_cond" or item.op == "call_if" or item.op == "goto" then
      if positions[item.target] ~= nil then
        counts[item.target] = (counts[item.target] or 0) + 1
      end
    end
  end
  return counts
end

-- The join of a region: the first index not reachable from the region's
-- entry without passing through the exit label. For the v1 peel we require
-- the fallthrough chain's terminal goto target to equal the else-chain
-- entry's join. Returns nil when the region cannot be proven structured.
-- `exit` is the enclosing region's exclusive bound: a join beyond it would
-- swallow items the enclosing structure still owns (duplicate labels).
---@param items table[]
---@param positions table<string, integer>
---@param entry integer
---@param exit integer|nil
---@return table|nil { join: integer, terminal: integer }
local function findJoin(items, positions, entry, exit)
  -- entry is an if_cond item; the join is the target of the fallthrough
  -- chain's terminal goto, and the conditional target must lie between.
  -- A backward conditional target, a join at or before the entry, or a join
  -- beyond the enclosing region's bound is an irreducible loop or an
  -- ownership violation (the structured if/else peel cannot own the region);
  -- those fall back to labels and gotos.
  local conditionalTarget = positions[items[entry].target]
  if conditionalTarget == nil then
    return nil
  end
  if conditionalTarget < entry then
    return nil
  end
  if exit ~= nil and conditionalTarget >= exit then
    return nil
  end
  local cursor = entry + 1
  while cursor <= #items do
    local item = items[cursor]
    if item.op == "goto" then
      local join = positions[item.target]
      if join == nil then
        return nil
      end
      if join < conditionalTarget or join <= entry then
        return nil
      end
      if exit ~= nil and join >= exit then
        return nil
      end
      return { join = join, terminal = cursor }
    elseif item.op == "if_cond" or item.op == "call_if" or item.op == "stop" or item.op == "return" then
      return nil
    end
    cursor = cursor + 1
  end
  return nil
end

-- Structure the linear item list recursively (forward declaration).
local structure

-- Emit the straight-line steps between two item indices (exclusive of
-- terminators and labels that are not region boundaries).
---@param items table[]
---@param from integer
---@param to integer
---@return table[] steps
local function linearSteps(items, from, to)
  -- unused in v1; retained for diagnostics
  items = items
  local out = {}
  for i = from, to do
    local item = items[i]
    if item.op == "label" then
      out[#out + 1] = { op = "label", name = item.name }
    elseif not isTerminator(item) then
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      out[#out + 1] = copy
    end
  end
  return out
end

-- Peel one conditional region: `if <condition> then <fallthrough> else
-- <target..join>`. Returns the steps plus the new cursor.
---@param items table[]
---@param entry integer
---@param join integer
---@param positions table<string, integer>
---@param depth integer
---@return table[] steps
local function peelConditional(items, entry, join, terminal, positions, depth, refCounts)
  local item = items[entry]
  local steps = {
    {
      op = "if",
      condition = negate(item.condition),
      -- The then-region is the fallthrough chain up to (not including) its
      -- terminal goto; the else-region is the conditional target's chain
      -- (the boundary label itself is consumed by the structure).
      yes = structure(items, entry + 1, terminal - 1, positions, depth + 1, refCounts),
      no = structure(items, positions[item.target] + 1, join - 1, positions, depth + 1, refCounts),
    },
  }
  return steps
end

structure = function(items, entry, exit, positions, depth, refCounts)
  local steps = {}
  local cursor = entry
  while cursor <= (exit or #items) do
    local item = items[cursor]
    if item.op == "label" then
      steps[#steps + 1] = { op = "label", name = item.name }
      cursor = cursor + 1
    elseif item.op == "if_cond" or item.op == "call_if" then
      local region = findJoin(items, positions, cursor, exit)
      -- The conditional target label must be owned by exactly this
      -- conditional; a second referent means the label is a region entry
      -- from outside, and the peel would consume a label the retained
      -- fallback gotos still need.
      local owned = region ~= nil and (refCounts[item.target] or 0) <= 1
      if owned then
        local peeled = peelConditional(items, cursor, region.join, region.terminal, positions, depth, refCounts)
        for _, step in ipairs(peeled) do
          steps[#steps + 1] = step
        end
        cursor = region.join
      else
        -- Irreducible or ambiguous: retain the label/goto fallback. A
        -- conditional call becomes a structured if wrapping the call (the
        -- call returns to the fallthrough position, so the semantics match
        -- the source CallIf exactly).
        if item.op == "call_if" then
          steps[#steps + 1] = {
            op = "if",
            condition = item.condition,
            yes = { { op = "call", target = item.target } },
            no = {},
          }
        else
          steps[#steps + 1] = {
            op = "goto_if",
            condition = item.condition,
            target = item.target,
          }
        end
        cursor = cursor + 1
      end
    elseif item.op == "goto" then
      -- A region-terminal goto that targets the region's own join falls
      -- through naturally and is dropped.
      if positions[item.target] ~= exit then
        steps[#steps + 1] = { op = "goto", target = item.target }
      end
      cursor = cursor + 1
    elseif item.op == "stop" or item.op == "return" or item.op == "next" then
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      steps[#steps + 1] = copy
      cursor = cursor + 1
    else
      local copy = {}
      for key, value in pairs(item) do
        copy[key] = value
      end
      steps[#steps + 1] = copy
      cursor = cursor + 1
    end
  end
  return steps
end

-- Structure a lowered script into a steps array.
---@param lowered table
---@param scriptIndex integer
---@return table steps
function Structurer.structure(lowered, scriptIndex)
  local items = lowered.items
  -- Label markers are inserted where if_cond/goto targets land.
  local positions = labelPositions(items)
  local stepPositions = {}
  for name, index in pairs(positions) do
    stepPositions[name] = index
  end
  -- The fallback target map for unresolved labels: every control target
  -- must resolve at compile time, so an unresolved target gets a synthesized
  -- label marker appended after the region and the positions map grows.
  for i, item in ipairs(items) do
    if (item.op == "if_cond" or item.op == "call_if" or item.op == "goto") and positions[item.target] == nil then
      items[#items + 1] = { op = "label", name = item.target }
      positions[item.target] = #items
    end
  end
  local refCounts = labelRefCounts(items, positions)
  return structure(items, 1, nil, positions, 0, refCounts)
end

return Structurer
