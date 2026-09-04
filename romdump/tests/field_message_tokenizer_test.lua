-- Lossless tokenization of decrypted message code units: glyphs, breaks,
-- extended controls, substitutions, and unsupported controls.
-- Fixture text is authored; retail message bytes never appear.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Tokenizer = require("romdump.src.digest.FieldMessageTokenizer")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local charmap = require("romdump.src.reference.hgss.charmap")

local T = {}

local function returnsCode(code, fn)
  local result, err = fn()
  Assert.isNil(result, "expected a failure result")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  local errorValue = assert(err) --[[@as Errors.Error]]
  Assert.equal(errorValue.code, code)
end

local function tokenize(units)
  return assert(Tokenizer.tokenize(units, charmap))
end

function T.marker_contract_matches_the_frozen_charmap()
  -- FieldMessageText.controlNames is the published marker format; it must
  -- agree with the frozen charmap reference so parsed/rendered markers always
  -- round trip with the names the importer emits.
  for code, name in pairs(charmap.controlNames) do
    Assert.equal(FieldMessageText.controlName(code), name, string.format("control 0x%04X name drift", code))
  end
  for code, name in pairs(FieldMessageText.controlNames) do
    Assert.equal(charmap.controlNames[code], name, string.format("control 0x%04X registry drift", code))
  end
end

function T.tokenizes_normal_glyphs_with_utf8_text()
  local tokens = tokenize({ 0x0141, 0x0153, 0x01DE, 0x0188, 0x01B3, 0xFFFF })
  Assert.equal(#tokens, 6)
  Assert.equal(tokens[1].kind, "glyph")
  Assert.equal(tokens[1].code, 0x0141)
  Assert.equal(tokens[1].text, "W")
  Assert.deepEqual(tokens[1].raw, { 0x0141 })
  Assert.equal(tokens[3].text, " ")
  Assert.equal(tokens[4].text, "é")
  Assert.equal(tokens[5].text, "’")
  Assert.equal(tokens[6].kind, "eos")
  Assert.deepEqual(tokens[6].raw, { 0xFFFF })
end

function T.tokenizes_source_symbol_glyphs()
  local tokens = tokenize({ 0x0014, 0x0051, 0x002C, 0x0022, 0x0030, 0x00EE, 0x0100, 0x0105, 0x011F, 0x0120, 0xFFFF })
  Assert.equal(tokens[1].kind, "glyph")
  Assert.equal(tokens[1].text, "こ")
  Assert.equal(tokens[2].text, "ん")
  Assert.equal(tokens[3].text, "に")
  Assert.equal(tokens[4].text, "ち")
  Assert.equal(tokens[5].text, "は")
  Assert.equal(tokens[6].text, "㊚")
  Assert.equal(tokens[7].text, "○")
  Assert.equal(tokens[8].text, "♫")
  Assert.equal(tokens[9].text, "‣")
  Assert.equal(tokens[10].text, "＆")
  Assert.equal(tokens[11].kind, "eos")
end

function T.tokenizes_packed_trainer_name_without_losing_the_message_eos()
  local tokens = tokenize({ FieldMessageText.TRNAME, 0x592B, 0x0FFC, 0xFFFF })
  Assert.equal(#tokens, 2)
  Assert.equal(tokens[1].kind, "substitution")
  Assert.equal(tokens[1].control, FieldMessageText.TRNAME)
  Assert.deepEqual(tokens[1].raw, { FieldMessageText.TRNAME, 0x592B, 0x0FFC })
  Assert.equal(tokens[2].kind, "eos")
  Assert.deepEqual(tokens[2].raw, { FieldMessageText.EOS })
end

function T.tokenizes_breaks_losslessly()
  local tokens = tokenize({ 0x0121, 0xE000, 0x0122, 0x25BC, 0x0123, 0x25BD, 0x0124, 0xFFFF })
  Assert.equal(tokens[2].kind, "line_break")
  Assert.equal(tokens[4].kind, "prompt_break")
  Assert.equal(tokens[6].kind, "page_break")
  Assert.deepEqual(tokens[4].raw, { 0x25BC })
end

function T.extended_control_structure_is_preserved()
  -- STRVAR_1 player-name form seen in the target banks: 0x0103 with args.
  local tokens = tokenize({ 0xFFFE, 0x0103, 0x0002, 0x0000, 0x0000, 0xFFFF })
  Assert.equal(#tokens, 2)
  Assert.equal(tokens[1].kind, "substitution")
  Assert.equal(tokens[1].control, 0x0103)
  Assert.deepEqual(tokens[1].args, { 0x0000, 0x0000 })
  Assert.deepEqual(tokens[1].raw, { 0xFFFE, 0x0103, 0x0002, 0x0000, 0x0000 })
end

function T.arg_count_is_not_assumed_constant()
  -- YESNO carries one argument; STRVAR in another bank may carry more.
  local yesno = tokenize({ 0xFFFE, 0x0200, 0x0001, 0x0000, 0xFFFF })
  Assert.equal(yesno[1].kind, "focus_indicator")
  Assert.deepEqual(yesno[1].args, { 0x0000 })
  local wide = tokenize({ 0xFFFE, 0x0100, 0x0003, 0x1, 0x2, 0x3, 0xFFFF })
  Assert.equal(wide[1].kind, "substitution")
  Assert.deepEqual(wide[1].args, { 0x0001, 0x0002, 0x0003 })
end

function T.strvar_families_classify_as_substitutions()
  for _, control in ipairs({ 0x0100, 0x01FF, 0x0300, 0x0400, 0x3400 }) do
    local tokens = tokenize({ 0xFFFE, control, 0x0000, 0xFFFF })
    Assert.equal(tokens[1].kind, "substitution", string.format("control %04x", control))
  end
end

function T.style_and_callback_controls_keep_their_kinds()
  local tokens = tokenize({ 0xFFFE, 0xFF00, 0x0001, 0x0001, 0xFFFE, 0x0202, 0x0000, 0xFFFF })
  Assert.equal(tokens[1].kind, "style")
  Assert.equal(tokens[1].control, 0xFF00)
  Assert.deepEqual(tokens[1].args, { 0x0001 })
  Assert.equal(tokens[2].kind, "printer_callback")
  Assert.equal(tokens[2].control, 0x0202)
end

function T.extended_continuations_keep_identity_and_consume_only_the_following_lf()
  local tokens = tokenize({
    0xFFFE,
    0x0207,
    0x0000,
    0xE000,
    0x0121,
    0xFFFE,
    0x0208,
    0x0000,
    0xE000,
    0x0122,
    0xFFFF,
  })
  Assert.equal(tokens[1].kind, "clear_continuation")
  Assert.equal(tokens[2].kind, "glyph")
  Assert.equal(tokens[2].code, 0x0121)
  Assert.equal(tokens[3].kind, "scroll_continuation")
  Assert.equal(tokens[4].kind, "glyph")
  Assert.equal(tokens[4].code, 0x0122)

  local fontDef = { charmap = { A = 0x0121, B = 0x0122 } }
  local clear = assert(FieldMessageText.parse("{UNK_207}", fontDef, { eos = false }))
  local scroll = assert(FieldMessageText.parse("{UNK_208}", fontDef, { eos = false }))
  Assert.equal(clear[1].control, 0x0207)
  Assert.equal(scroll[1].control, 0x0208)
  Assert.equal(FieldMessageText.tokensToText(clear), "{UNK_207}")
  Assert.equal(FieldMessageText.tokensToText(scroll), "{UNK_208}")
end

function T.extended_continuations_do_not_skip_a_non_lf_token()
  local tokens = tokenize({ 0xFFFE, 0x0207, 0x0000, 0x0121, 0xFFFF })
  Assert.equal(tokens[2].kind, "glyph")
  Assert.equal(tokens[2].code, 0x0121)
end

function T.unknown_extended_control_is_visible_not_dropped()
  local tokens = tokenize({ 0xFFFE, 0x0707, 0x0001, 0x0009, 0xFFFF })
  Assert.equal(tokens[1].kind, "unsupported_control")
  Assert.equal(tokens[1].control, 0x0707)
  Assert.deepEqual(tokens[1].args, { 0x0009 })
  Assert.deepEqual(tokens[1].raw, { 0xFFFE, 0x0707, 0x0001, 0x0009 })
end

function T.unknown_single_unit_control_is_visible()
  local tokens = tokenize({ 0xF200, 0xFFFF })
  Assert.equal(tokens[1].kind, "unsupported_control")
  Assert.equal(tokens[1].control, 0xF200)
end

function T.truncated_extended_control_is_typed()
  returnsCode("MESSAGE_CONTROL_TRUNCATED", function()
    return Tokenizer.tokenize({ 0xFFFE, 0x0100 }, charmap)
  end)
  returnsCode("MESSAGE_CONTROL_TRUNCATED", function()
    return Tokenizer.tokenize({ 0xFFFE, 0x0100, 0x0005, 0x0001 }, charmap)
  end)
end

function T.truncated_packed_trainer_name_is_typed()
  returnsCode("MESSAGE_TRNAME_TRUNCATED", function()
    return Tokenizer.tokenize({ FieldMessageText.TRNAME, 0x012B }, charmap)
  end)
end

function T.unmapped_glyph_code_is_typed()
  -- 0x0001 (kana 'a') is outside the English selected-set reference.
  returnsCode("MESSAGE_GLYPH_UNMAPPED", function()
    return Tokenizer.tokenize({ 0x0001, 0xFFFF }, charmap)
  end)
end

function T.trainer_name_code_is_a_substitution()
  local tokens = tokenize({ 0xF100, 0xFFFF })
  Assert.equal(tokens[1].kind, "substitution")
  Assert.equal(tokens[1].control, 0xF100)
  Assert.deepEqual(tokens[1].args, {})
end

function T.stream_is_lossless_through_eos()
  local units = {
    0x013A,
    0x0156,
    0x0153,
    0x014A,
    0x0149,
    0x0157,
    0x0157,
    0x0153,
    0x0156,
    0x01DE,
    0xFFFE,
    0x0103,
    0x0002,
    0x0000,
    0x0000,
    0xE000,
    0x25BC,
    0x25BD,
    0xFFFF,
  }
  local tokens = tokenize(units)
  local rebuilt = {}
  for _, token in ipairs(tokens) do
    for _, unit in ipairs(token.raw) do
      rebuilt[#rebuilt + 1] = unit
    end
  end
  Assert.deepEqual(rebuilt, units)
end

return { tests = T }
