-- Display-text rendering from token streams: the modder-facing "text" half of
-- the message asset contract (GMM-style markers, nothing dropped).

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

local T = {}

-- Charcodes follow the English charmap (0x0121 = '0', 0x012B = 'A',
-- 0x0145 = 'a', 0x01AB = '!', 0x01DE = space).
local FONT = {
  charmap = {
    ["P"] = 0x013A,
    ["r"] = 0x0156,
    ["o"] = 0x0153,
    ["f"] = 0x014A,
    ["e"] = 0x0149,
    ["s"] = 0x0157,
    ["m"] = 0x0151,
    ["E"] = 0x012F,
    ["l"] = 0x0150,
    ["n"] = 0x0152,
    ["G"] = 0x0131,
    ["O"] = 0x0139,
    ["L"] = 0x0138,
    ["D"] = 0x012E,
    ["i"] = 0x014D,
    ["H"] = 0x0132,
    ["I"] = 0x0133,
    ["v"] = 0x015A,
    ["b"] = 0x0146,
    ["g"] = 0x014B,
    ["t"] = 0x0158,
    ["k"] = 0x014F,
    ["c"] = 0x0147,
    ["u"] = 0x0159,
    ["w"] = 0x015B,
    ["a"] = 0x0145,
    ["4"] = 0x0125,
    ["9"] = 0x012A,
    ["!"] = 0x01AB,
    [" "] = 0x01DE,
    ["é"] = 0x0188,
    ["’"] = 0x01B3,
    [":"] = 0x01C4,
    [","] = 0x01AD,
  },
}

local function returnsCode(code, fn)
  local result, err = fn()
  Assert.isNil(result, "expected a failure result")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

function T.code_unit_constants_match_charcode_h()
  Assert.equal(FieldMessageText.CHAR_LF, 0xE000)
  Assert.equal(FieldMessageText.EXT_CTRL_CODE_BEGIN, 0xFFFE)
  Assert.equal(FieldMessageText.EOS, 0xFFFF)
  Assert.equal(FieldMessageText.PROMPT_BREAK, 0x25BC)
  Assert.equal(FieldMessageText.PAGE_BREAK, 0x25BD)
  Assert.equal(FieldMessageText.TRNAME, 0xF100)
  -- STRVAR control codes are family base + field selector.
  Assert.equal(FieldMessageText.STRVAR_1 + 3, 0x0103)
  Assert.equal(FieldMessageText.COLOR, 0xFF00)
  Assert.equal(FieldMessageText.YESNO, 0x0200)
end

function T.renders_glyphs_breaks_and_eos()
  local text = FieldMessageText.tokensToText({
    { kind = "glyph", code = 0x0141, text = "W" },
    { kind = "glyph", code = 0x0153, text = "o" },
    { kind = "line_break", raw = { 0xE000 } },
    { kind = "glyph", code = 0x0121, text = "0" },
    { kind = "prompt_break", raw = { 0x25BC } },
    { kind = "glyph", code = 0x01DE, text = " " },
    { kind = "page_break", raw = { 0x25BD } },
    { kind = "glyph", code = 0x0188, text = "é" },
    { kind = "eos", raw = { 0xFFFF } },
  })
  Assert.equal(text, "Wo\n0\r \fé")
end

function T.renders_strvar_markers_gmm_style()
  local text = FieldMessageText.tokensToText({
    { kind = "substitution", control = 0x0103, name = "STRVAR_1", args = { 0, 0 } },
    { kind = "substitution", control = 0x0100, name = "STRVAR_1", args = { 1, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  })
  Assert.equal(text, "{STRVAR_1 3, 0, 0}{STRVAR_1 0, 1, 0}")
end

function T.renders_other_controls_with_names_and_args()
  local text = FieldMessageText.tokensToText({
    { kind = "unsupported_control", control = 0x0200, name = "YESNO", args = { 0 } },
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 } },
    { kind = "wait", control = 0x0202, name = "WAIT", args = {} },
    { kind = "substitution", control = 0xF100, name = "TRNAME", args = {} },
    { kind = "eos", raw = { 0xFFFF } },
  })
  Assert.equal(text, "{YESNO 0}{COLOR 1}{WAIT}{TRNAME}")
end

function T.renders_unknown_controls_as_ctrl_markers()
  local text = FieldMessageText.tokensToText({
    { kind = "unsupported_control", control = 0x0707, name = nil, args = {} },
    { kind = "unsupported_control", control = 0x0708, name = nil, args = { 9 } },
    { kind = "unsupported_control", control = 0xE001, name = nil, args = {} },
    { kind = "eos", raw = { 0xFFFF } },
  })
  Assert.equal(text, "{CTRL 0x0707}{CTRL 0x0708 9}{CTRL 0xE001}")
end

function T.marker_builds_gmm_style_markers()
  Assert.equal(FieldMessageText.marker(FieldMessageText.STRVAR_1 + 3, 0, 0), "{STRVAR_1 3, 0, 0}")
  Assert.equal(FieldMessageText.marker(FieldMessageText.COLOR, 1), "{COLOR 1}")
  Assert.equal(FieldMessageText.marker(FieldMessageText.WAIT), "{WAIT}")
  Assert.equal(FieldMessageText.marker(FieldMessageText.YESNO, 0), "{YESNO 0}")
  Assert.equal(FieldMessageText.marker(0x0707), "{CTRL 0x0707}")
  Assert.equal(FieldMessageText.marker(0x0708, 9), "{CTRL 0x0708 9}")
end

function T.control_name_and_kind_helpers()
  Assert.equal(FieldMessageText.controlName(0x0103), "STRVAR_1")
  Assert.equal(FieldMessageText.controlName(0xFF00), "COLOR")
  Assert.isNil(FieldMessageText.controlName(0x0707))
  Assert.equal(FieldMessageText.controlKind(0x0103), "substitution")
  Assert.equal(FieldMessageText.controlKind(0x0200), "unsupported_control")
  Assert.equal(FieldMessageText.controlKind(0xFF00), "style")
  Assert.equal(FieldMessageText.controlKind(0x0202), "wait")
  Assert.isTrue(FieldMessageText.isStrvarFamily(0x3401))
  Assert.isFalse(FieldMessageText.isStrvarFamily(0x0200))
end

function T.parse_reads_marker_text_back_into_tokens()
  local tokens =
    assert(FieldMessageText.parse("Professor Elm: Hi, {STRVAR_1 3, 0, 0}!\nI’ve been waiting!\r{CURSOR_X 4}", FONT))
  Assert.equal(tokens[1].kind, "glyph")
  Assert.equal(tokens[1].code, 0x013A)
  local strvar, cursor, breaks = nil, nil, {}
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" and token.control == 0x0103 then
      strvar = token
    end
    if token.kind == "unsupported_control" and token.control == 0x0203 then
      cursor = token
    end
    if token.kind == "line_break" or token.kind == "prompt_break" then
      breaks[#breaks + 1] = token.kind
    end
  end
  Assert.notNil(strvar)
  Assert.deepEqual(assert(strvar).args, { 0, 0 })
  Assert.equal(assert(strvar).name, "STRVAR_1")
  Assert.notNil(cursor)
  Assert.deepEqual(assert(cursor).args, { 4 })
  Assert.deepEqual(breaks, { "line_break", "prompt_break" })
  Assert.equal(tokens[#tokens].kind, "eos")
  -- Marker glyphs resolve through the font def charmap.
  local parsed = assert(FieldMessageText.parse("{STRVAR_1 3, 0, 0} Pokémon", FONT))
  Assert.equal(parsed[6].kind, "glyph")
  Assert.equal(parsed[6].text, "é")
end

function T.parse_round_trips_through_tokens_to_text()
  local text = "Professor Elm: Hi, {STRVAR_1 3, 0, 0}!\nI’ve been waiting!\r" .. "{CURSOR_X 4}{CTRL 0x0707 9}"
  local tokens = assert(FieldMessageText.parse(text, FONT))
  Assert.equal(FieldMessageText.tokensToText(tokens), text)
  -- And the reverse: a rendered token stream parses back to the same text.
  local original = {
    { kind = "glyph", code = 0x013A, text = "P" },
    { kind = "prompt_break", raw = { 0x25BC } },
    { kind = "substitution", control = 0x0100, name = "STRVAR_1", args = { 1, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local rendered = FieldMessageText.tokensToText(original)
  local reparsed = assert(FieldMessageText.parse(rendered, FONT))
  Assert.equal(FieldMessageText.tokensToText(reparsed), rendered)
end

function T.parse_omits_eos_when_requested()
  local tokens = assert(FieldMessageText.parse("GOLD", FONT, { eos = false }))
  Assert.equal(#tokens, 4)
  Assert.equal(tokens[4].text, "D")
end

function T.parse_errors_are_typed()
  returnsCode("MESSAGE_MARKER_INVALID", function()
    return FieldMessageText.parse("P {STRVAR_1 3", FONT)
  end)
  returnsCode("MESSAGE_MARKER_INVALID", function()
    return FieldMessageText.parse("{NO_SUCH 1}", FONT)
  end)
  returnsCode("MESSAGE_MARKER_INVALID", function()
    return FieldMessageText.parse("{STRVAR_1}", FONT)
  end)
  returnsCode("MESSAGE_MARKER_INVALID", function()
    return FieldMessageText.parse("{CTRL 0xZZZZ}", FONT)
  end)
  returnsCode("MESSAGE_MARKER_INVALID", function()
    return FieldMessageText.parse("{COLOR many}", FONT)
  end)
  returnsCode("MESSAGE_SUBSTITUTION_UNRESOLVED", function()
    return FieldMessageText.parse("Z", FONT)
  end)
end

function T.tokens_after_eos_are_ignored()
  local text = FieldMessageText.tokensToText({
    { kind = "glyph", code = 0x013A, text = "P" },
    { kind = "eos", raw = { 0xFFFF } },
    { kind = "glyph", code = 0x013A, text = "P" },
    { kind = "line_break", raw = { 0xE000 } },
    { kind = "substitution", control = 0x0103, name = "STRVAR_1", args = { 0, 0 } },
    { kind = "prompt_break", raw = { 0x25BC } },
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 1 } },
  })
  Assert.equal(text, "P")
end

function T.nothing_is_dropped_from_the_text_form()
  local tokens = {
    { kind = "glyph", code = 0x013A, text = "P" },
    { kind = "line_break", raw = { 0xE000 } },
    { kind = "substitution", control = 0x0103, name = "STRVAR_1", args = { 0, 0 } },
    { kind = "prompt_break", raw = { 0x25BC } },
    { kind = "page_break", raw = { 0x25BD } },
    { kind = "unsupported_control", control = 0x0200, name = "YESNO", args = { 0 } },
    { kind = "style", control = 0xFF00, name = "COLOR", args = { 0 } },
    { kind = "wait", control = 0x0201, name = "PAUSE", args = {} },
    { kind = "eos", raw = { 0xFFFF } },
  }
  Assert.equal(FieldMessageText.tokensToText(tokens), "P\n{STRVAR_1 3, 0, 0}\r\f{YESNO 0}{COLOR 0}{PAUSE}")
end

return T
