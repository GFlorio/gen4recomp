-- Pure dialogue pagination: converts a formatted token stream into immutable
-- pages of wrapped lines inside a fixed reference width. Layout never depends
-- on window size, rendering, or love; glyph advances come from a metrics
-- object (the generated font definition) so substitution happens upstream and
-- resizing never repaginates. EOS is terminal: the first EOS ends pagination
-- and every later token is ignored.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class DialogueLayout
local DialogueLayout = {}

local DEFAULT_MAX_LINES = 2
local BREAK_KINDS = {
  prompt_break = "prompt",
  page_break = "page",
  clear_continuation = "clear",
  scroll_continuation = "scroll",
}

-- metrics: { glyphWidth(code) -> integer }
-- metrics also carries the printer lineHeight and lineSpacing when available.
-- resolving glyph advances. Every non-glyph token is zero-width.
-- opts: { width = integer, maxLines = integer }
-- Returns { pages = { { lines = { { tokens, width } }, breakKind } }, warnings }.
-- breakKind is "prompt", "page", "line", "overflow", or "eos".

---@param state table<string, unknown>
---@return table<string, unknown>
local function currentLine(state)
  return state.lines[#state.lines]
end

---@param state table<string, unknown>
---@return boolean
local function hasContent(state)
  for _, line in ipairs(state.lines) do
    if #line.tokens > 0 then
      return true
    end
  end
  return false
end

---@param state table<string, unknown>
local function beginLine(state)
  state.lines[#state.lines + 1] = { tokens = {}, width = 0 }
end

---@param state table<string, unknown>
---@param breakKind string
local function pushPage(state, breakKind)
  state.pages[#state.pages + 1] = { lines = state.lines, breakKind = breakKind }
  state.lines = {}
end

-- Ends the current page, then starts a fresh line for subsequent content
-- (except at EOS, which is terminal).
---@param state table<string, unknown>
---@param breakKind string
local function endPage(state, breakKind)
  if hasContent(state) then
    pushPage(state, breakKind)
  end
  if breakKind ~= "eos" then
    beginLine(state)
  end
end

-- One token-width rule for every layout calculation: a glyph contributes
-- its advance and every control token contributes nothing. Carried tokens
-- keep the same rule, so a word wrapped to a new line keeps its exact width.
---@param token MessageToken
---@param metrics FieldDialogueTheme.Metrics
---@return integer?
local function tokenWidth(token, metrics)
  if token.kind == "glyph" then
    return metrics.glyphWidth(token.code)
  end
  return 0
end

-- Finds the trailing breakable space on the current line; returns its token
-- index and the width of the tokens before it (space excluded). Every token
-- width uses the same tokenWidth rule, so wrap points stay exact.
---@param state table<string, unknown>
---@param metrics FieldDialogueTheme.Metrics
---@return integer?, integer?
local function lastBreakableSpace(state, metrics)
  local line = currentLine(state)
  local running = 0
  local breakIndex, keptWidth
  for i, token in ipairs(line.tokens) do
    local w = tokenWidth(token, metrics)
    running = running + w
    if token.kind == "glyph" and token.text == " " then
      breakIndex = i
      keptWidth = running - w
    end
  end
  return breakIndex, keptWidth
end

---@param line table<string, unknown>
---@param token MessageToken
---@param width integer
local function appendToken(line, token, width)
  line.tokens[#line.tokens + 1] = token
  line.width = line.width + width
end

---@param state table<string, unknown>
---@param token MessageToken
local function carryAfterBreak(state, token)
  local line = currentLine(state)
  local advance = assert(tokenWidth(token, state.metrics))
  appendToken(line, token, advance)
end

---@param state table<string, unknown>
---@param token MessageToken
local function placeGlyph(state, token)
  local advance = tokenWidth(token, state.metrics)
  if advance == nil then
    Errors.raise(
      FieldErrors.FONT_GLYPH_MISSING,
      "no advance for glyph code " .. string.format("0x%04X", token.code),
      { code = token.code }
    )
  end
  ---@cast advance integer
  local line = currentLine(state)
  -- A space at a wrap point or at the start of a fresh line carries no
  -- visual width; drop it instead of leaving ragged leading/trailing gaps.
  if token.text == " " and (#line.tokens == 0 or line.width + advance > state.width) then
    return
  end
  if advance > state.width then
    state.warnings[#state.warnings + 1] = {
      kind = "overwide",
      code = token.code,
      width = advance,
      boxWidth = state.width,
    }
  end
  if state.sourcePositioned then
    appendToken(line, token, advance)
  elseif line.width + advance > state.width and #line.tokens > 0 then
    local breakIndex, keptWidth = lastBreakableSpace(state, state.metrics)
    if #state.lines >= state.maxLines then
      endPage(state, "overflow")
      line = currentLine(state)
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
      beginLine(state)
      for _, carriedToken in ipairs(carried) do
        carryAfterBreak(state, carriedToken)
      end
      line = currentLine(state)
    else
      beginLine(state)
      line = currentLine(state)
    end
  end
  if not state.sourcePositioned or line.tokens[#line.tokens] ~= token then
    appendToken(line, token, advance)
  end
end

---@param state table<string, unknown>
---@param token MessageToken
---@return boolean
local function processControlToken(state, token)
  local breakKind = BREAK_KINDS[token.kind]
  if breakKind then
    endPage(state, breakKind)
    return true
  end
  if token.kind == "line_break" then
    if state.sourcePositioned or #state.lines < state.maxLines then
      beginLine(state)
    else
      endPage(state, "line")
    end
    return true
  end
  return false
end

---@param state table<string, unknown>
---@param token MessageToken
local function processToken(state, token)
  if token.kind == "eos" then
    endPage(state, "eos")
  elseif token.kind == "glyph" then
    placeGlyph(state, token)
  elseif not processControlToken(state, token) then
    -- style/wait/focus_indicator/substitution/unsupported tokens are
    -- zero-width and cannot be split: keep them at their source position
    -- so reveal ordering and diagnostic fidelity survive pagination.
    appendToken(currentLine(state), token, 0)
  end
end

---@param tokens MessageToken[]
---@param metrics FieldDialogueTheme.Metrics
---@param opts { width: integer, maxLines?: integer, sourcePositioned?: boolean }
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

  local state = {
    metrics = metrics,
    width = width,
    maxLines = maxLines,
    sourcePositioned = opts.sourcePositioned,
    pages = {},
    lines = {},
    warnings = {},
  }

  beginLine(state)

  for _, token in ipairs(tokens) do
    processToken(state, token)
    if token.kind == "eos" then
      break
      -- Terminal: flush the page and ignore everything after the first EOS.
    end
  end

  if hasContent(state) then
    pushPage(state, "eos")
  end

  return {
    pages = state.pages,
    warnings = state.warnings,
    lineHeight = metrics.lineHeight or 16,
    lineSpacing = metrics.lineSpacing or 0,
    syntheticBreaks = opts.sourcePositioned and 0 or nil,
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
---@field textOriginX integer?
---@field textOriginY integer?
---@field contentWidth integer?
---@field syntheticBreaks integer?

return DialogueLayout
