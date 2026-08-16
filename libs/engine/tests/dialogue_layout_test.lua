-- Pure dialogue pagination tests: width wrapping, explicit breaks, page
-- boundaries, and over-wide glyph handling.
-- All fixtures are authored token streams with a synthetic font metric table.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local DialogueLayout = require("libs.engine.src.DialogueLayout")

local T = {}

-- Synthetic metrics over a small font def table: code -> advance.
local function metrics(def)
  return {
    glyphWidth = function(code)
      local glyph = def[code]
      return glyph and glyph.advance or nil
    end,
  }
end

local FONT = {
  [0x0121] = { advance = 6 },
  [0x0122] = { advance = 6 },
  [0x0123] = { advance = 6 },
  [0x01DE] = { advance = 6 }, -- space
  [0x01AE] = { advance = 6 }, -- period
}

local function glyphs(spec)
  local tokens = {}
  for i = 1, #spec do
    tokens[i] = {
      kind = "glyph",
      code = spec:byte(i) == 32 and 0x01DE or 0x0121,
      text = spec:sub(i, i),
      raw = { spec:byte(i) == 32 and 0x01DE or 0x0121 },
    }
  end
  return tokens
end

local function textOf(line)
  local out = {}
  for _, token in ipairs(line.tokens) do
    if token.kind == "glyph" then
      out[#out + 1] = token.text
    end
  end
  return table.concat(out)
end

function T.wraps_on_width_and_prefers_breakable_spaces()
  -- "AAAA BBBB" at width 24: the wrap space is dropped, words fill both lines.
  local layout = DialogueLayout.layout(glyphs("AAAA BBBB"), metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#layout.pages, 1)
  Assert.equal(#layout.pages[1].lines, 2)
  Assert.equal(textOf(layout.pages[1].lines[1]), "AAAA")
  Assert.equal(layout.pages[1].lines[1].width, 24)
  Assert.equal(textOf(layout.pages[1].lines[2]), "BBBB")
  Assert.equal(layout.pages[1].breakKind, "eos")
end

function T.full_page_overflows_to_a_new_page()
  -- 5 words at one word per line: 2 lines per page, final page ends on eos.
  local more = DialogueLayout.layout(glyphs("AAAA BBBB CCCC DDDD EEEE"), metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#more.pages, 3)
  Assert.equal(textOf(more.pages[1].lines[1]), "AAAA")
  Assert.equal(textOf(more.pages[1].lines[2]), "BBBB")
  Assert.equal(more.pages[1].breakKind, "overflow")
  Assert.equal(textOf(more.pages[2].lines[1]), "CCCC")
  Assert.equal(textOf(more.pages[2].lines[2]), "DDDD")
  Assert.equal(more.pages[2].breakKind, "overflow")
  Assert.equal(textOf(more.pages[3].lines[1]), "EEEE")
  Assert.equal(more.pages[3].breakKind, "eos")
end

function T.explicit_line_break_starts_a_line_and_flushes_at_capacity()
  local function withBreaks(count)
    local tokens = glyphs("AAAA")
    local position = 5
    for _ = 1, count do
      tokens[position] = { kind = "line_break", raw = { 0xE000 } }
      position = position + 1
      for i = position, position + 3 do
        tokens[i] = tokens[i - position + 1]
      end
      position = position + 4
    end
    return tokens
  end
  local layout = DialogueLayout.layout(withBreaks(1), metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#layout.pages, 1)
  Assert.equal(textOf(layout.pages[1].lines[1]), "AAAA")
  Assert.equal(textOf(layout.pages[1].lines[2]), "AAAA")

  -- Three hard lines exceed the two-line page.
  local three = DialogueLayout.layout(withBreaks(2), metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#three.pages, 2)
  Assert.equal(three.pages[1].breakKind, "line")
  Assert.equal(textOf(three.pages[2].lines[1]), "AAAA")
end

function T.prompt_and_page_breaks_boundary_pages()
  local tokens = {}
  local function wordsAnd(breaks)
    for _, breakToken in ipairs(breaks) do
      for _, glyphToken in ipairs(glyphs("AAAA")) do
        tokens[#tokens + 1] = glyphToken
      end
      tokens[#tokens + 1] = breakToken
    end
  end
  wordsAnd({
    { kind = "prompt_break", raw = { 0x25BC } },
    { kind = "page_break", raw = { 0x25BD } },
  })
  -- Final word after the last break, then EOS.
  for _, glyphToken in ipairs(glyphs("AAAA")) do
    tokens[#tokens + 1] = glyphToken
  end
  tokens[#tokens + 1] = { kind = "eos", raw = { 0xFFFF } }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#layout.pages, 3)
  Assert.equal(layout.pages[1].breakKind, "prompt")
  Assert.equal(textOf(layout.pages[1].lines[1]), "AAAA")
  Assert.equal(layout.pages[2].breakKind, "page")
  Assert.equal(textOf(layout.pages[2].lines[1]), "AAAA")
  Assert.equal(layout.pages[3].breakKind, "eos")
  Assert.equal(textOf(layout.pages[3].lines[1]), "AAAA")
end

function T.overwide_glyph_is_placed_alone_and_traced()
  local wideFont = {
    [0x0121] = { advance = 60 },
  }
  local tokens = {
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local layout = DialogueLayout.layout(tokens, metrics(wideFont), { width = 24 })
  Assert.equal(#layout.pages, 1)
  Assert.equal(textOf(layout.pages[1].lines[1]), "A")
  Assert.equal(layout.pages[1].lines[1].width, 60)
  Assert.equal(#layout.warnings, 2)
  Assert.equal(layout.warnings[1].kind, "overwide")
  Assert.equal(layout.warnings[1].code, 0x0121)
end

function T.style_and_unresolved_tokens_take_no_layout_width()
  local tokens = {
    { kind = "style", control = 0xFF00, args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 2, 0, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24 })
  Assert.equal(#layout.pages, 1)
  Assert.equal(#layout.pages[1].lines[1].tokens, 3) -- style + glyph + substitution
  Assert.equal(layout.pages[1].lines[1].width, 6)
end

function T.empty_and_control_only_messages_close_safely()
  local empty = DialogueLayout.layout({ { kind = "eos", raw = { 0xFFFF } } }, metrics(FONT), { width = 24 })
  Assert.equal(#empty.pages, 0)
  local onlyControl = DialogueLayout.layout(
    { { kind = "prompt_break", raw = { 0x25BC } }, { kind = "eos", raw = { 0xFFFF } } },
    metrics(FONT),
    { width = 24 }
  )
  Assert.equal(#onlyControl.pages, 0)
end

function T.missing_glyph_advance_is_typed()
  local err = Assert.throws(function()
    return DialogueLayout.layout(
      { { kind = "glyph", code = 0x0001, text = "?", raw = { 0x0001 } }, { kind = "eos", raw = { 0xFFFF } } },
      metrics(FONT),
      { width = 24 }
    )
  end)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, "FONT_GLYPH_MISSING")
end

function T.layout_is_immutable_across_reuse()
  local tokens = glyphs("AAAA BBBB")
  local a = DialogueLayout.layout(tokens, metrics(FONT), { width = 24, maxLines = 2 })
  local b = DialogueLayout.layout(tokens, metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(textOf(a.pages[1].lines[1]), textOf(b.pages[1].lines[1]))
  Assert.equal(#a.pages, #b.pages)
  -- Re-laying out after reading never changes the source token stream.
  Assert.equal(#tokens, 9)
end

-- Controls are pure geometry-free markers: a line of COLOR + YESNO tokens
-- measures only the glyph advance.
function T.controls_are_zero_width()
  local tokens = {
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } },
    { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = { 0 }, raw = { 0xFFFE, 0x0200, 1, 0 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24 })
  Assert.equal(layout.pages[1].lines[1].width, 6, "a control-heavy line measures only the glyph advance")
end

function T.controls_preserve_source_order()
  local tokens = {
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = { 0 }, raw = { 0xFFFE, 0x0200, 1, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24 })
  local line = layout.pages[1].lines[1]
  Assert.equal(line.tokens[1].control, 0xFF00)
  Assert.equal(line.tokens[2].kind, "glyph")
  Assert.equal(line.tokens[3].control, 0x0200)
end

function T.controls_never_generate_an_overwide_warning()
  -- Only glyphs can overrun the width budget; zero-width controls placed
  -- anywhere in the stream never produce the overwide trace.
  local tokens = {
    { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = { 0 }, raw = { 0xFFFE, 0x0200, 1, 0 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "glyph", code = 0x0121, text = "A", raw = { 0x0121 } },
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24 })
  Assert.equal(#layout.warnings, 0, "zero-width controls are never overwide")
end

function T.zero_width_controls_do_not_change_wrap_positions()
  local decorated = {}
  for i, token in ipairs(glyphs("AAAA BBBB")) do
    if i == 4 then
      decorated[#decorated + 1] = {
        kind = "focus_indicator",
        control = 0x0200,
        name = "YESNO",
        args = { 0 },
        raw = { 0xFFFE, 0x0200, 1, 0 },
      }
    end
    if i == 7 then
      decorated[#decorated + 1] = {
        kind = "style",
        control = 0xFF00,
        name = "COLOR",
        args = { 1 },
        raw = { 0xFFFE, 0xFF00, 1, 1 },
      }
    end
    decorated[#decorated + 1] = token
  end
  local opts = { width = 24, maxLines = 2 }
  local plain = DialogueLayout.layout(glyphs("AAAA BBBB"), metrics(FONT), opts)
  local withControls = DialogueLayout.layout(decorated, metrics(FONT), opts)
  Assert.equal(#withControls.pages, #plain.pages)
  for p = 1, #plain.pages do
    Assert.equal(#withControls.pages[p].lines, #plain.pages[p].lines, "page " .. p .. " wraps identically")
    for l = 1, #plain.pages[p].lines do
      Assert.equal(withControls.pages[p].lines[l].width, plain.pages[p].lines[l].width)
    end
  end
end

function T.eos_is_terminal_ignoring_later_glyphs_and_markers()
  local tokens = {}
  for _, t in ipairs(glyphs("AAAA")) do
    tokens[#tokens + 1] = t
  end
  tokens[#tokens + 1] = { kind = "eos", raw = { 0xFFFF } }
  for _, t in ipairs(glyphs("BBBB")) do
    tokens[#tokens + 1] = t
  end
  tokens[#tokens + 1] = { kind = "style", control = 0xFF00, args = { 1 }, raw = { 0xFFFE, 0xFF00, 1, 1 } }
  tokens[#tokens + 1] = { kind = "page_break", raw = { 0x25BD } }
  tokens[#tokens + 1] = { kind = "prompt_break", raw = { 0x25BC } }
  local layout = DialogueLayout.layout(tokens, metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#layout.pages, 1)
  Assert.equal(layout.pages[1].breakKind, "eos")
  Assert.equal(#layout.pages[1].lines, 1)
  Assert.equal(textOf(layout.pages[1].lines[1]), "AAAA")
  Assert.equal(layout.pages[1].lines[1].width, 24)
  Assert.equal(#layout.warnings, 0)
end

function T.carried_word_glyphs_keep_exact_line_width()
  -- "AA B CCCC" at width 24: the first space is dropped on the full line,
  -- then the wrap at the next glyph carries "B" onto the new line. The
  -- carried glyph must count toward the new line's width, or "CCCC" wrongly
  -- fits next to the carried word and the final wrap never happens.
  local layout = DialogueLayout.layout(glyphs("AA B CCCC"), metrics(FONT), { width = 24, maxLines = 2 })
  Assert.equal(#layout.pages, 2)
  Assert.equal(layout.pages[1].breakKind, "overflow")
  Assert.equal(textOf(layout.pages[1].lines[1]), "AA")
  Assert.equal(layout.pages[1].lines[1].width, 12)
  Assert.equal(textOf(layout.pages[1].lines[2]), "BCCC")
  Assert.equal(layout.pages[1].lines[2].width, 24)
  Assert.equal(layout.pages[2].breakKind, "eos")
  Assert.equal(textOf(layout.pages[2].lines[1]), "C")
  Assert.equal(layout.pages[2].lines[1].width, 6)
end

return { tests = T }
