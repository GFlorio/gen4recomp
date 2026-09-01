-- Resolves the absolute MAIN/SUB OBJ palette-bank ownership used by the HGSS
-- Oak source templates. The source transfer order is significant: each
-- resdat palette record reserves consecutive banks on its configured engine.

local Errors = require("libs.errors.src.Errors")

local IntroObjPaletteResolver = {}

IntroObjPaletteResolver.ERROR = {
  INVALID_LAYOUT = "INTRO_OBJ_PALETTE_LAYOUT_INVALID",
  INVALID_SLOT = "INTRO_OBJ_PALETTE_SLOT_INVALID",
}

local function invalidLayout(message, context)
  Errors.raise(IntroObjPaletteResolver.ERROR.INVALID_LAYOUT, message, context or {})
end

local function invalidSlot(message, context)
  Errors.raise(IntroObjPaletteResolver.ERROR.INVALID_SLOT, message, context or {})
end

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end

local function validateRecord(record, index, objectIds)
  if type(record) ~= "table" then
    invalidLayout("intro palette layout record is invalid", { index = index })
  end
  for _, field in ipairs({ "objectId", "narcId", "fileId", "compressed", "vram", "bankCount" }) do
    if not integer(record[field]) or record[field] < 0 then
      invalidLayout("intro palette layout record has an invalid " .. field, { index = index, field = field })
    end
  end
  if record.vram < 1 or record.vram > 3 then
    invalidLayout("intro palette layout record has an unsupported VRAM target", {
      index = index,
      vram = record.vram,
    })
  end
  if record.bankCount <= 0 then
    invalidLayout("intro palette layout record must reserve at least one bank", {
      index = index,
      bankCount = record.bankCount,
    })
  end
  if objectIds[record.objectId] then
    invalidLayout("intro palette layout contains a duplicate resource id", { objectId = record.objectId })
  end
  objectIds[record.objectId] = true
end

--- Allocate records in source order into independent absolute engine-bank maps.
---@param records table[] dense source-order palette records
---@return { main: table, sub: table }
function IntroObjPaletteResolver.build(records)
  if type(records) ~= "table" then
    invalidLayout("intro palette layout records are required")
  end
  local layout = { main = {}, sub = {} }
  local cursor = { main = 0, sub = 0 }
  local objectIds = {}
  for index, record in ipairs(records) do
    validateRecord(record, index, objectIds)
    if record.vram == 1 or record.vram == 3 then
      for localBank = 0, record.bankCount - 1 do
        layout.main[cursor.main] = { record = record, localBank = localBank }
        cursor.main = cursor.main + 1
      end
    end
    if record.vram == 2 or record.vram == 3 then
      for localBank = 0, record.bankCount - 1 do
        layout.sub[cursor.sub] = { record = record, localBank = localBank }
        cursor.sub = cursor.sub + 1
      end
    end
  end
  return layout
end

--- Look up the owner and local NCLR bank for an absolute engine bank.
---@param layout { main: table, sub: table }
---@param engine "main"|"sub"
---@param paletteNumber integer
---@return table owner resdat palette record
---@return integer localBank zero-based bank within the owner's NCLR
function IntroObjPaletteResolver.owner(layout, engine, paletteNumber)
  if
    type(layout) ~= "table"
    or type(layout.main) ~= "table"
    or type(layout.sub) ~= "table"
    or (engine ~= "main" and engine ~= "sub")
  then
    invalidSlot("intro palette engine is invalid", { engine = engine })
  end
  if not integer(paletteNumber) or paletteNumber < 0 then
    invalidSlot("intro absolute palette slot is invalid", { paletteNumber = paletteNumber })
  end
  local slot = layout[engine][paletteNumber]
  if not slot then
    invalidSlot("intro absolute palette slot has no owner", {
      engine = engine,
      paletteNumber = paletteNumber,
    })
  end
  return slot.record, slot.localBank
end

--- Extract one exact 16-color bank from a decoded 4bpp palette resource.
---@param colors table[] flat decoded palette colors
---@param depth integer decoded character depth; only 3 (4bpp) is supported
---@param localBank integer zero-based NCLR bank
---@return table[]
function IntroObjPaletteResolver.slice(colors, depth, localBank)
  if type(colors) ~= "table" or depth ~= 3 then
    invalidSlot("intro palette slice requires a 4bpp palette resource", { depth = depth })
  end
  if not integer(localBank) or localBank < 0 then
    invalidSlot("intro local palette bank is invalid", { localBank = localBank })
  end
  if #colors == 0 or #colors % 16 ~= 0 or (localBank + 1) * 16 > #colors then
    invalidSlot("intro local palette bank is outside the decoded palette resource", {
      localBank = localBank,
      colorCount = #colors,
    })
  end
  local view = {}
  local start = localBank * 16
  for index = 1, 16 do
    view[index] = colors[start + index]
  end
  return view
end

return IntroObjPaletteResolver
