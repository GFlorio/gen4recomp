-- Pure dialogue pagination: converts a formatted token stream into immutable
-- pages of wrapped lines inside a fixed reference width. Layout never depends
-- on window size, rendering, or love; glyph advances come from a metrics
-- object (the generated font definition) so substitution happens upstream and
-- resizing never repaginates (spec sections 14.3 and 15.4).

local Errors = require("libs.rom.src.Errors")

local DialogueLayout = {}

local DEFAULT_MAX_LINES = 2

-- metrics: { glyphWidth(code) -> integer } resolving glyph advances.
-- opts: { width = integer, maxLines = integer }
-- Returns { pages = { { lines = { { tokens, width } }, breakKind } }, warnings }.
-- breakKind is "prompt", "page", "line", "overflow", or "eos".
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

  -- Finds the trailing breakable space on the current line; returns its token
  -- index and the width of the tokens before it (space excluded).
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
            local kept = {}
            for i = 1, breakIndex - 1 do kept[#kept + 1] = line.tokens[i] end
            line.tokens = kept
            line.width = keptWidth
            beginLine()
            line = currentLine()
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
      -- style/wait/unsupported/substitution tokens have no layout width, but
      -- they stay in the line so the renderer can apply their behavior.
      currentLine().tokens[#currentLine().tokens + 1] = token
    end
  end

  if hasContent() then
    pushPage("eos")
  end

  return { pages = pages, warnings = warnings }
end

return DialogueLayout
