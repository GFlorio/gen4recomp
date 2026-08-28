-- Import-time lossless tokenizer over decrypted HGSS message code units
-- (romdump digester; the runtime never sees raw code units). Single-unit
-- specials follow include/constants/charcode.h (CHAR_LF 0xE000, EOS 0xFFFF);
-- the prompt/page breaks (0x25BC = GMM \r, 0x25BD = GMM \f) and the extended
-- control framing (EXT_CTRL_CODE_BEGIN 0xFFFE, count, arguments) follow
-- charmap.txt and src/string_control_code.c. Glyph display text and control
-- names come from the frozen charmap reference; widths are resolved later from
-- the font, never here. Pure module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local FieldMessageText = require("libs.assets.src.FieldMessageText")

local FieldMessageTokenizer = {}

-- Code-unit constants, control classification, and control names are the
-- marker contract and live in FieldMessageText; this digester only walks raw
-- code units.

local function tokenizeUnits(units, charmap)
  local tokens = {}
  local index = 0
  while index < #units do
    local code = units[index + 1]
    local raw = { code }
    if code == FieldMessageText.EOS then
      tokens[#tokens + 1] = { kind = "eos", raw = raw }
      index = index + 1
    elseif code == FieldMessageText.EXT_CTRL_CODE_BEGIN then
      if index + 3 > #units then
        Errors.raise(
          "MESSAGE_CONTROL_TRUNCATED",
          "extended control at code-unit " .. index .. " lacks its control code or argument count",
          { codeUnitIndex = index, code = code }
        )
      end
      local control = units[index + 2]
      local argumentCount = units[index + 3]
      if index + 3 + argumentCount > #units then
        Errors.raise(
          "MESSAGE_CONTROL_TRUNCATED",
          "extended control "
            .. string.format("0x%04X", control)
            .. " declares "
            .. argumentCount
            .. " arguments but only "
            .. (#units - index - 3)
            .. " code units remain",
          { codeUnitIndex = index, control = control, argumentCount = argumentCount, remaining = #units - index - 3 }
        )
      end
      local args = {}
      for a = 1, argumentCount do
        args[a] = units[index + 3 + a]
      end
      local controlRaw = {}
      for i = 0, 2 + argumentCount do
        controlRaw[i + 1] = units[index + 1 + i]
      end
      tokens[#tokens + 1] = {
        kind = FieldMessageText.controlKind(control),
        control = control,
        name = FieldMessageText.controlName(control),
        args = args,
        raw = controlRaw,
      }
      index = index + 3 + argumentCount
      if
        (control == FieldMessageText.UNK_207 or control == FieldMessageText.UNK_208)
        and units[index + 1] == FieldMessageText.CHAR_LF
      then
        index = index + 1
      end
    elseif code == FieldMessageText.CHAR_LF then
      tokens[#tokens + 1] = { kind = "line_break", raw = raw }
      index = index + 1
    elseif code == FieldMessageText.PROMPT_BREAK then
      tokens[#tokens + 1] = { kind = "prompt_break", raw = raw }
      index = index + 1
    elseif code == FieldMessageText.PAGE_BREAK then
      tokens[#tokens + 1] = { kind = "page_break", raw = raw }
      index = index + 1
    elseif code == FieldMessageText.TRNAME then
      tokens[#tokens + 1] = {
        kind = "substitution",
        control = code,
        name = "TRNAME",
        args = {},
        raw = raw,
      }
      index = index + 1
    elseif code < FieldMessageText.CHAR_LF then
      local text = charmap.glyphs[code]
      if text == nil then
        Errors.raise(
          "MESSAGE_GLYPH_UNMAPPED",
          string.format("glyph code 0x%04X has no charmap display text", code),
          { code = code, codeUnitIndex = index }
        )
      end
      tokens[#tokens + 1] = { kind = "glyph", code = code, text = text, raw = raw }
      index = index + 1
    else
      tokens[#tokens + 1] = {
        kind = "unsupported_control",
        control = code,
        args = {},
        raw = raw,
      }
      index = index + 1
    end
  end
  return tokens
end

-- units: decrypted u16 code units (FieldMessageBank output). charmap: the
-- frozen reference (romdump/src/reference/hgss/charmap.lua). Returns the lossless
-- token stream; raises MESSAGE_CONTROL_TRUNCATED / MESSAGE_GLYPH_UNMAPPED.
function FieldMessageTokenizer.tokenize(units, charmap, _)
  assert(type(units) == "table", "tokenize requires a code-unit array")
  assert(type(charmap) == "table" and type(charmap.glyphs) == "table", "tokenize requires the frozen charmap reference")
  local ok, result = pcall(tokenizeUnits, units, charmap)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldMessageTokenizer
