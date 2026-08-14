-- Per-runtime Start Menu action registry: mods add menu actions through
-- descriptors (id, label, icon, targetApplication, placement) that carry no
-- UI callback, and the registry is sealed before the first menu open.
-- Placement constraints (before/after) resolve against the full semantic
-- canonical order (§29.1: the order the policy's build sequence defines, not
-- the currently visible subset, so an anchor stays meaningful while a
-- neighboring canonical destination is absent). Duplicates, the reserved
-- vanilla.* ids, unknown anchors, and placement cycles are rejected with
-- diagnostics naming the actions involved; compose merges the sealed mod
-- entries into the StartMenuPolicy build output and raises the structured
-- START_MENU_CAPACITY_EXCEEDED diagnostic when the composed visible list
-- exceeds the generated slot capacity. Pure domain module: no love, no I/O,
-- no registries.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class StartMenuRegistryOptions
---@field canonicalIds string[] the full semantic canonical action ids in build order (§29.1)
---@field capacity integer the generated action slot capacity (manifest slots minus the cancel slot)

---@class StartMenuRegistry
---@field sealed boolean
---@field _canonicalIds string[]
---@field _capacity integer
---@field _descriptors table<string, table> validated descriptors by id
---@field _order string[] registration order
---@field _mods table[]? sealed, placement-resolved mod entries in final order
local StartMenuRegistry = {}
StartMenuRegistry.__index = StartMenuRegistry

-- The reserved Pokégear-family display positions: the source writes special
-- actions 9/10 to positions 7/8 unconditionally (StartMenu_BuildActionLists,
-- start_menu.c:485-522), so those slots are never handed to normal entries.
local RESERVED_POSITIONS = { [7] = true, [8] = true }

local function invalidDescriptor(message, context)
  Errors.raise(FieldErrors.START_MENU_REGISTRY_INVALID_DESCRIPTOR, message, context)
end

function StartMenuRegistry.new(options)
  assert(options and type(options.canonicalIds) == "table", "the start menu registry requires the canonical order")
  assert(type(options.capacity) == "number", "the start menu registry requires the action slot capacity")
  assert(
    options.capacity > 0 and options.capacity == math.floor(options.capacity),
    "the start menu action slot capacity must be a positive integer"
  )
  local seen = {}
  for _, id in ipairs(options.canonicalIds) do
    assert(type(id) == "string" and id ~= "", "canonical action ids must be non-empty strings")
    assert(seen[id] == nil, "canonical action ids must be distinct")
    seen[id] = true
  end
  return setmetatable({
    sealed = false,
    _canonicalIds = options.canonicalIds,
    _capacity = options.capacity,
    _descriptors = {},
    _order = {},
    _mods = nil,
  }, StartMenuRegistry)
end

-- Registers one mod action descriptor. Placement is exactly one of
-- `before`/`after` naming a canonical action id or an earlier mod id.
---@param descriptor { id: string, label: string, icon?: string, targetApplication?: string, placement?: { before?: string, after?: string } }
function StartMenuRegistry:register(descriptor)
  if self.sealed then
    Errors.raise(FieldErrors.START_MENU_REGISTRY_ALREADY_SEALED, "cannot register a start menu action after seal", {})
  end
  if type(descriptor) ~= "table" or type(descriptor.id) ~= "string" or descriptor.id == "" then
    invalidDescriptor("start menu actions need a non-empty id", { id = descriptor and descriptor.id })
  end
  if type(descriptor.label) ~= "string" or descriptor.label == "" then
    invalidDescriptor("start menu action " .. descriptor.id .. " needs a label message ref", { id = descriptor.id })
  end
  if descriptor.icon ~= nil and type(descriptor.icon) ~= "string" then
    invalidDescriptor("start menu action " .. descriptor.id .. " icon must be an asset id", { id = descriptor.id })
  end
  if descriptor.targetApplication ~= nil and type(descriptor.targetApplication) ~= "string" then
    invalidDescriptor(
      "start menu action " .. descriptor.id .. " target application must be an id",
      { id = descriptor.id }
    )
  end
  local placement = descriptor.placement
  if placement ~= nil then
    if type(placement) ~= "table" then
      invalidDescriptor("start menu action " .. descriptor.id .. " placement must be a table", { id = descriptor.id })
    end
    local before = placement.before
    local after = placement.after
    local count = (before ~= nil and 1 or 0) + (after ~= nil and 1 or 0)
    if
      count ~= 1
      or (before ~= nil and (type(before) ~= "string" or before == ""))
      or (after ~= nil and (type(after) ~= "string" or after == ""))
    then
      invalidDescriptor(
        "start menu action " .. descriptor.id .. " placement must name exactly one anchor",
        { id = descriptor.id }
      )
    end
  end
  if self._descriptors[descriptor.id] ~= nil then
    Errors.raise(FieldErrors.START_MENU_REGISTRY_DUPLICATE_ID, "duplicate start menu action id", { id = descriptor.id })
  end
  if descriptor.id:sub(1, #"vanilla.") == "vanilla." then
    Errors.raise(
      FieldErrors.START_MENU_REGISTRY_RESERVED_ID,
      "mods cannot replace a canonical start menu action",
      { id = descriptor.id }
    )
  end
  self._descriptors[descriptor.id] = descriptor
  self._order[#self._order + 1] = descriptor.id
end

-- Whether an anchor is resolvable: a canonical action id or an already
-- placed mod id.
---@param known table<string, boolean>
---@param anchor string
---@return boolean
local function anchorResolved(known, anchor)
  return known[anchor] == true
end

---@param id string
---@return boolean
function StartMenuRegistry:_isCanonical(id)
  for _, canonical in ipairs(self._canonicalIds) do
    if canonical == id then
      return true
    end
  end
  return false
end

-- Resolves every placement into one deterministic mod order. Every anchor
-- must be a canonical action id or a registered mod id (forward references
-- resolve through the placement fixpoint); an unknown anchor is a malformed
-- descriptor. Mods are inserted into the canonical order (or after/before
-- already placed mods) in registration order; a pass that makes no progress
-- means the remaining actions form a placement cycle, diagnosed by naming
-- two of them.
function StartMenuRegistry:seal()
  if self.sealed then
    Errors.raise(FieldErrors.START_MENU_REGISTRY_ALREADY_SEALED, "the start menu registry is already sealed", {})
  end
  local registeredModIds = {}
  for _, id in ipairs(self._order) do
    registeredModIds[id] = true
  end
  for _, id in ipairs(self._order) do
    local entry = self._descriptors[id]
    local placement = entry.placement
    if placement ~= nil then
      local anchor = placement.before or placement.after
      if not self:_isCanonical(anchor) and not registeredModIds[anchor] then
        Errors.raise(FieldErrors.START_MENU_REGISTRY_UNKNOWN_ANCHOR, "unknown start menu placement anchor", {
          id = entry.id,
          anchor = anchor,
        })
      end
    end
  end
  local ordered = {}
  for index, id in ipairs(self._canonicalIds) do
    ordered[index] = id
  end
  local known = {}
  for _, id in ipairs(ordered) do
    known[id] = true
  end
  local pending = {}
  for _, id in ipairs(self._order) do
    pending[#pending + 1] = self._descriptors[id]
  end
  local placed = {}
  while #pending > 0 do
    local progressed = false
    local remaining = {}
    for _, descriptor in ipairs(pending) do
      local placement = descriptor.placement
      local anchor = placement and (placement.before or placement.after)
      if anchor == nil or anchorResolved(known, anchor) then
        if anchor ~= nil then
          local targetIndex = nil
          for index, id in ipairs(ordered) do
            if id == anchor then
              targetIndex = index
              break
            end
          end
          assert(targetIndex ~= nil, "resolved anchor must be present in the order")
          local insertion = placement.before == anchor and targetIndex or targetIndex + 1
          table.insert(ordered, insertion, descriptor.id)
          known[descriptor.id] = true
        else
          ordered[#ordered + 1] = descriptor.id
          known[descriptor.id] = true
        end
        placed[#placed + 1] = descriptor
        progressed = true
      else
        remaining[#remaining + 1] = descriptor
      end
    end
    if not progressed then
      Errors.raise(FieldErrors.START_MENU_REGISTRY_PLACEMENT_CYCLE, "start menu placement cycle", {
        ids = #remaining >= 2 and { remaining[1].id, remaining[2].id } or { remaining[1].id },
      })
    end
    pending = remaining
  end
  self._mods = placed
  self.sealed = true
end

local function requireSealed(self)
  if not self.sealed then
    Errors.raise(FieldErrors.START_MENU_REGISTRY_NOT_SEALED, "the start menu registry is not sealed", {})
  end
end

-- Merges the sealed mod actions into the StartMenuPolicy build output. The
-- mod entries carry the same §20 projections as canonical entries (a missing
-- optional target is a capability-disabled action, never a selection-time
-- failure). Display positions are assigned over the present entries in the
-- merged order, with the reserved Pokégear-family positions 7/8 untouched;
-- the composed visible list must fit the generated slot capacity or
-- construction fails with the structured START_MENU_CAPACITY_EXCEEDED
-- diagnostic naming the visible ids and count. Fresh tables per call; the
-- policy entries are never mutated.
---@param entries table[] StartMenuPolicy build output
---@param capabilities table<string, boolean> the registered application-id set
---@return table[]
function StartMenuRegistry:compose(entries, capabilities)
  requireSealed(self)
  assert(type(capabilities) == "table", "the composed actions require the capability set")
  if #self._mods == 0 then
    return entries
  end
  local merged = {}
  for _, entry in ipairs(entries) do
    local copy = {}
    for key, value in pairs(entry) do
      copy[key] = value
    end
    merged[#merged + 1] = copy
  end
  local capabilitySet = {}
  for _, id in ipairs(capabilities) do
    capabilitySet[id] = true
  end
  for _, descriptor in ipairs(self._mods) do
    -- A placement-less mod lands at the end of the merged order, mirroring
    -- its seal-time append to the canonical order.
    local insertion = #merged + 1
    if descriptor.placement ~= nil then
      local targetIndex = nil
      for index, entry in ipairs(merged) do
        if entry.id == descriptor.placement.before or entry.id == descriptor.placement.after then
          targetIndex = index
          break
        end
      end
      assert(targetIndex ~= nil, "a sealed mod anchor must exist in the canonical entries")
      insertion = descriptor.placement.before ~= nil and targetIndex or targetIndex + 1
    end
    local targetApplication = descriptor.targetApplication
    local capabilityAvailable = targetApplication ~= nil and capabilitySet[targetApplication] == true
    table.insert(merged, insertion, {
      id = descriptor.id,
      sourceAction = "mod",
      message = descriptor.label,
      targetApplication = targetApplication,
      present = true,
      vanillaEnabled = true,
      capabilityAvailable = capabilityAvailable,
      enabled = capabilityAvailable,
      normalVisible = capabilityAvailable,
      developerVisible = true,
    })
  end
  local present = {}
  local presentCount = 0
  for _, entry in ipairs(merged) do
    if entry.present == true then
      presentCount = presentCount + 1
      present[#present + 1] = entry
    end
  end
  if presentCount > self._capacity then
    local ids = {}
    for index, entry in ipairs(present) do
      ids[index] = entry.id
    end
    Errors.raise(FieldErrors.START_MENU_CAPACITY_EXCEEDED, "the composed start menu exceeds the slot capacity", {
      ids = ids,
      count = presentCount,
    })
  end
  local counter = 0
  for _, entry in ipairs(merged) do
    if entry.present == true then
      local reserved = entry.displayPosition ~= nil and RESERVED_POSITIONS[entry.displayPosition] == true
      if not reserved then
        while RESERVED_POSITIONS[counter] do
          counter = counter + 1
        end
        entry.displayPosition = counter
        counter = counter + 1
      end
    end
  end
  return merged
end

return StartMenuRegistry
