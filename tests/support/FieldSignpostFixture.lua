-- Synthetic signpost-renderer fixtures shared by the fake-graphics unit suite
-- and the canonical goldens: a FieldSignpostController opened through a canned
-- layout in a chosen source-type/wipe/print state, and the immutable
-- FieldWindowStyles catalogue built from the field-UI fixture manifest. The
-- standard text is two glyph lines (A, B of the fixture font) so goldens can
-- paste the glyph colors independently.

local FieldSignpostController = require("libs.engine.src.FieldSignpostController")
local FieldWindowStyles = require("libs.engine.src.FieldWindowStyles")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local FieldSignpostFixture = {}

local function glyph(text, code)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function line(tokens)
  return { tokens = tokens, width = 0 }
end

-- A formatted message carrying the layout lines the canned layout returns
-- verbatim (the same convention as the controller's own unit tests).
---@param lines { tokens: MessageToken[] }[]
---@return table
function FieldSignpostFixture.message(lines)
  local tokens = {}
  for _, ln in ipairs(lines) do
    for _, token in ipairs(ln.tokens) do
      tokens[#tokens + 1] = token
    end
  end
  return { bankId = 543, messageId = 5, tokens = tokens, _lines = lines }
end

-- The standard two-line text (glyph A, then B, then a second line of A) every
-- golden render and position assertion uses.
---@return { tokens: MessageToken[] }[]
function FieldSignpostFixture.textLines()
  return {
    line({ glyph("A", 1), glyph("B", 2) }),
    line({ glyph("A", 1) }),
  }
end

-- The immutable hgss.* style catalogue the fixture manifest drives (the same
-- builtins FieldRuntime builds from the generated manifest).
---@return FieldWindowStyles
function FieldSignpostFixture.styles()
  return FieldWindowStyles.new(FieldUiFixture.manifest())
end

-- A controller shown at the chosen source type, wiped to the chosen offset
-- (steps of 16 within -48..0), with the standard text printed instantly
-- unless opts.text == false. The wipe command completes its endpoint exactly
-- as the source does; the command returns to nop on the following update.
---@param lines { tokens: MessageToken[] }[]
---@param opts { type?: integer, map?: integer, offset?: integer, styleId?: string, text?: boolean }?
---@return FieldSignpostController
function FieldSignpostFixture.shown(lines, opts)
  opts = opts or {}
  local controller = FieldSignpostController.new({
    layout = function(msg)
      ---@cast msg any
      return { lines = msg._lines }
    end,
    styleId = opts.styleId,
  })
  controller:setSourceAppearance({ game = "hgss", type = opts.type or 2, map = opts.map or 0 })
  controller:setCommand("show")
  controller:updateFixed()
  if opts.offset then
    FieldSignpostFixture.wipeTo(controller, opts.offset)
  end
  if opts.text ~= false then
    controller:printInstant(FieldSignpostFixture.message(lines))
  end
  return controller
end

-- Wipes the controller to an exact logical offset. The fixture only needs
-- step-aligned targets, so the wipe always reaches the target on a motion
-- update; the held command is left as-is (a following update would complete
-- it), matching the real fixed-tick timeline.
---@param controller FieldSignpostController
---@param target integer
function FieldSignpostFixture.wipeTo(controller, target)
  local command = target < controller:status().logicalYOffset and "wipe_out" or "wipe_in"
  controller:setCommand(command)
  while controller:status().logicalYOffset ~= target do
    controller:updateFixed()
  end
end

return FieldSignpostFixture
