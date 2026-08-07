-- Pure dialogue pagination: converts a formatted token stream into immutable
-- pages of wrapped lines inside a fixed reference width. Layout never depends
-- on window size, rendering, or love; glyph advances come from a metrics
-- object (the generated font definition) so substitution happens upstream and
-- resizing never repaginates (spec sections 14.3 and 15.4).

local Errors = require("libs.rom.src.Errors")

---@class DialogueLayout
local DialogueLayout = {}

local DEFAULT_MAX_LINES = 2

-- metrics: { glyphWidth(code) -> integer, nonGlyphWidth(token) -> integer|nil }
-- resolving glyph advances and, optionally, the typeset width of marker
-- tokens (spec section 15.4: control tokens have explicit width behavior).
-- Without nonGlyphWidth, non-glyph tokens stay widthless.
-- opts: { width = integer, maxLines = integer }
-- Returns { pages = { { lines = { { tokens, width } }, breakKind } }, warnings }.
-- breakKind is "prompt", "page", "line", "overflow", or "eos".

---@param tokens MessageToken[]
---@param metrics FieldDialogueTheme.Metrics
---@param opts { width: integer, maxLines?: integer }
---@return DialogueLayout.Result
function DialogueLayout.layout(tokens, metrics, opts)
  assert(type(tokens) == "table", "layout requires a token stream")
  assert(type(metrics) == "table" and type(metrics.glyphWidth) == "function",
    "layout requires a metrics object with glyphWidth(code)")
  opts = opts or {}
  local width = assert(opts.width, "layout requires opts.width")
  local maxLines = opts.maxLines or DEFAULT_MAX_LINES
  assert(width > 0 and maxLines > 0, "layout width and maxLines must be positive")

  local pages = {}
  local lines = {}   -- array of { tokens = {}, width = 0 }
  local warnings = {}

  local function currentLine()
    return lines[#lines]
  end

  local function hasContent()
    for _, line in ipairs(lines) do
      if #line.tokens > 0 then return true end
    end
    return false
  end

  local function beginLine()
    lines[#lines + 1] = { tokens = {}, width = 0 }
  end

  local function pushPage(breakKind)
    pages[#pages + 1] = { lines = lines, breakKind = breakKind }
    lines = {}
  end

  -- Ends the current page, then starts a fresh line for subsequent content
  -- (except at EOS, which is terminal).
  local function endPage(breakKind)
    if hasContent() then
      pushPage(breakKind)
    end
    if breakKind ~= "eos" then
      beginLine()
    end
  end

  -- Width contribution of a non-glyph token: measured marker width when the
  -- metrics object provides it, otherwise zero.
  local function extraWidth(token)
    if not metrics.nonGlyphWidth then return 0 end
    local measured = metrics.nonGlyphWidth(token)
    return type(measured) == "number" and measured or 0
  end

  -- Finds the trailing breakable space on the current line; returns its token
  -- index and the width of the tokens before it (space excluded). Marker
  -- widths count toward the running width so wrap points stay exact.
  local function lastBreakableSpace()
    local line = currentLine()
    local running = 0
    local breakIndex, keptWidth
    for i, token in ipairs(line.tokens) do
      if token.kind == "glyph" then
        running = running + metrics.glyphWidth(token.code)
        if token.text == " " then
          breakIndex = i
          keptWidth = running - metrics.glyphWidth(token.code)
        end
      else
        running = running + extraWidth(token)
      end
    end
    return breakIndex, keptWidth
  end

  beginLine()

  for _, token in ipairs(tokens) do
    if token.kind == "glyph" then
      local advance = metrics.glyphWidth(token.code)
      if advance == nil then
        Errors.raise("FONT_GLYPH_MISSING",
          "no advance for glyph code " .. string.format("0x%04X", token.code),
          { code = token.code })
      end
      local line = currentLine()
      -- A space at a wrap point or at the start of a fresh line carries no
      -- visual width; drop it instead of leaving ragged leading/trailing gaps.
      if token.text == " " and (#line.tokens == 0 or line.width + advance > width) then
        -- fall through: space is dropped
      else
        if advance > width then
          warnings[#warnings + 1] = {
            kind = "overwide",
            code = token.code,
            width = advance,
            boxWidth = width,
          }
        end
        if line.width + advance > width and #line.tokens > 0 then
          local breakIndex, keptWidth = lastBreakableSpace()
          if #lines >= maxLines then
            endPage("overflow")
            line = currentLine()
          elseif breakIndex then
            -- Wrap at the last breakable space; non-glyph tokens placed after
            -- the space (markers) carry to the new line instead of vanishing.
            local kept = {}
            local carried = {}
            for i = 1, breakIndex - 1 do kept[#kept + 1] = line.tokens[i] end
            for i = breakIndex + 1, #line.tokens do
              carried[#carried + 1] = line.tokens[i]
            end
            line.tokens = kept
            line.width = keptWidth
            beginLine()
            line = currentLine()
            for _, token in ipairs(carried) do
              line.tokens[#line.tokens + 1] = token
              line.width = line.width + extraWidth(token)
            end
          else
            beginLine()
            line = currentLine()
          end
        end
        line.tokens[#line.tokens + 1] = token
        line.width = line.width + advance
      end
    elseif token.kind == "line_break" then
      if #lines >= maxLines then
        endPage("line")
      else
        beginLine()
      end
    elseif token.kind == "prompt_break" then
      endPage("prompt")
    elseif token.kind == "page_break" then
      endPage("page")
    elseif token.kind == "eos" then
      endPage("eos")
    else
      -- style/wait/substitution/unsupported tokens keep their measured marker
      -- width (zero when the metrics object does not provide one), so a
      -- rendered marker never overlaps the following glyphs. A marker that
      -- pushes the line past the budget is placed anyway and traced, exactly
      -- like an over-wide glyph (spec section 15.4): markers cannot be split.
      local extra = extraWidth(token)
      local line = currentLine()
      if line.width + extra > width then
        warnings[#warnings + 1] = {
          kind = "overwide",
          control = token.control,
          width = line.width + extra,
          boxWidth = width,
        }
      end
      line.tokens[#line.tokens + 1] = token
      line.width = line.width + extra
    end
  end

  if hasContent() then
    pushPage("eos")
  end

  return { pages = pages, warnings = warnings }
end

-- One wrapped line of the current page: tokens plus the rendered width.

---@class DialogueLayout.Line
---@field tokens MessageToken[]
---@field width integer

-- One page: wrapped lines plus the break that ended it ("prompt", "page",
-- "line", "overflow", or "eos").

---@class DialogueLayout.Page
---@field lines DialogueLayout.Line[]
---@field breakKind "prompt"|"page"|"line"|"overflow"|"eos"

-- A traced layout problem (e.g. a glyph or marker wider than the box).

---@class DialogueLayout.Warning
---@field kind "overwide"
---@field code integer?
---@field control integer?
---@field width integer
---@field boxWidth integer

-- The immutable layout result consumed by the dialogue controller.

---@class DialogueLayout.Result
---@field pages DialogueLayout.Page[]
---@field warnings DialogueLayout.Warning[]

return DialogueLayout
