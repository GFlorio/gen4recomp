-- Pure dialogue pagination: converts a formatted token stream into immutable
-- pages of wrapped lines inside a fixed reference width. Layout never depends
-- on window size, rendering, or love; glyph advances come from a metrics
-- object (the generated font definition) so substitution happens upstream and
-- resizing never repaginates. EOS is terminal: the first EOS ends pagination
-- and every later token is ignored.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class DialogueLayout
local DialogueLayout = {}

local DEFAULT_MAX_LINES = 2

-- metrics: { glyphWidth(code) -> integer }
-- metrics also carries the printer lineHeight and lineSpacing when available.
-- resolving glyph advances. Every non-glyph token is zero-width.
-- opts: { width = integer, maxLines = integer }
-- Returns { pages = { { lines = { { tokens, width } }, breakKind } }, warnings }.
-- breakKind is "prompt", "page", "line", "overflow", or "eos".

---@param tokens MessageToken[]
---@param metrics FieldDialogueTheme.Metrics
---@param opts { width: integer, maxLines?: integer }
---@return DialogueLayout.Result
function DialogueLayout.layout(tokens, metrics, opts)
  assert(type(tokens) == "table", "layout requires a token stream")
  assert(
    type(metrics) == "table" and type(metrics.glyphWidth) == "function",
    "layout requires a metrics object with glyphWidth(code)"
  )
  opts = opts or {}
  local width = assert(opts.width, "layout requires opts.width")
  local maxLines = opts.maxLines or DEFAULT_MAX_LINES
  assert(width > 0 and maxLines > 0, "layout width and maxLines must be positive")

  local pages = {}
  local lines = {} -- array of { tokens = {}, width = 0 }
  local warnings = {}

  local function currentLine()
    return lines[#lines]
  end

  local function hasContent()
    for _, line in ipairs(lines) do
      if #line.tokens > 0 then
        return true
      end
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

  -- One token-width rule for every layout calculation: a glyph contributes
  -- its advance and every control token contributes nothing. Carried tokens
  -- keep the same rule, so a word wrapped to a new line keeps its exact width.
  local function tokenWidth(token)
    if token.kind == "glyph" then
      return metrics.glyphWidth(token.code)
    end
    return 0
  end

  -- Finds the trailing breakable space on the current line; returns its token
  -- index and the width of the tokens before it (space excluded). Every token
  -- width uses the same tokenWidth rule, so wrap points stay exact.
  local function lastBreakableSpace()
    local line = currentLine()
    local running = 0
    local breakIndex, keptWidth
    for i, token in ipairs(line.tokens) do
      local w = tokenWidth(token)
      running = running + w
      if token.kind == "glyph" and token.text == " " then
        breakIndex = i
        keptWidth = running - w
      end
    end
    return breakIndex, keptWidth
  end

  beginLine()

  for _, token in ipairs(tokens) do
    if token.kind == "eos" then
      -- Terminal: flush the page and ignore everything after the first EOS.
      endPage("eos")
      break
    elseif token.kind == "glyph" then
      local advance = tokenWidth(token)
      if advance == nil then
        Errors.raise(
          FieldErrors.FONT_GLYPH_MISSING,
          "no advance for glyph code " .. string.format("0x%04X", token.code),
          { code = token.code }
        )
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
            -- Wrap at the last breakable space; the tokens placed after the
            -- space (glyphs and non-glyph tokens) carry to the new line with
            -- their exact width instead of vanishing.
            local kept = {}
            local carried = {}
            for i = 1, breakIndex - 1 do
              kept[#kept + 1] = line.tokens[i]
            end
            for i = breakIndex + 1, #line.tokens do
              carried[#carried + 1] = line.tokens[i]
            end
            line.tokens = kept
            line.width = keptWidth
            beginLine()
            line = currentLine()
            for _, carriedToken in ipairs(carried) do
              line.tokens[#line.tokens + 1] = carriedToken
              line.width = line.width + tokenWidth(carriedToken)
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
    elseif token.kind == "clear_continuation" then
      endPage("clear")
    elseif token.kind == "scroll_continuation" then
      endPage("scroll")
    else
      -- style/wait/focus_indicator/substitution/unsupported tokens are
      -- zero-width and cannot be split: keep them at their source position
      -- so reveal ordering and diagnostic fidelity survive pagination.
      local line = currentLine()
      line.tokens[#line.tokens + 1] = token
    end
  end

  if hasContent() then
    pushPage("eos")
  end

  return {
    pages = pages,
    warnings = warnings,
    lineHeight = metrics.lineHeight or 16,
    lineSpacing = metrics.lineSpacing or 0,
  }
end

-- One wrapped line of the current page: tokens plus the rendered width.

---@class DialogueLayout.Line
---@field tokens MessageToken[]
---@field width integer

-- One page: wrapped lines plus the break that ended it ("prompt", "page",
-- "line", "overflow", or "eos").

---@class DialogueLayout.Page
---@field lines DialogueLayout.Line[]
---@field breakKind "prompt"|"page"|"clear"|"scroll"|"line"|"overflow"|"eos"

-- A traced layout problem (a glyph token wider than the box).

---@class DialogueLayout.Warning
---@field kind "overwide"
---@field code integer?
---@field width integer
---@field boxWidth integer

-- The immutable layout result consumed by the dialogue controller.

---@class DialogueLayout.Result
---@field pages DialogueLayout.Page[]
---@field warnings DialogueLayout.Warning[]
---@field lineHeight integer
---@field lineSpacing integer

return DialogueLayout
