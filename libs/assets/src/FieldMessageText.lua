-- The GMM-style marker contract for field message text assets: constants for
-- the code units and control families, the control-name registry, and the
-- three marker operations -- render a token stream to text (tokensToText),
-- build a single marker (marker), and parse marker text back into a token
-- stream (parse). Code units follow include/constants/charcode.h and the
-- function-code names follow charmap.txt in the pinned pret/pokeheartgold
-- checkout; the registry is the published marker format, so it is verified
-- against the frozen charmap reference by the importer tests. Pure module:
-- no love dependency.

local Errors = require("libs.rom.src.Errors")

local FieldMessageText = {}

-- Single-unit code units (include/constants/charcode.h).
FieldMessageText.CHAR_LF = 0xE000
FieldMessageText.EXT_CTRL_CODE_BEGIN = 0xFFFE
FieldMessageText.EOS = 0xFFFF
FieldMessageText.PROMPT_BREAK = 0x25BC
FieldMessageText.PAGE_BREAK = 0x25BD
FieldMessageText.TRNAME = 0xF100

-- Extended-control family bases (charmap.txt function codes). A STRVAR
-- control code is its family base plus a field selector in the low byte:
-- STRVAR_1 + 3 = 0x0103 renders as {STRVAR_1 3, 0, 0}.
FieldMessageText.STRVAR_1 = 0x0100
FieldMessageText.STRVAR_3 = 0x0300
FieldMessageText.STRVAR_4 = 0x0400
FieldMessageText.STRVAR_34 = 0x3400
FieldMessageText.YESNO = 0x0200
FieldMessageText.PAUSE = 0x0201
FieldMessageText.WAIT = 0x0202
FieldMessageText.CURSOR_X = 0x0203
FieldMessageText.CURSOR_Y = 0x0204
FieldMessageText.ALN_CENTER = 0x0205
FieldMessageText.ALN_RIGHT = 0x0206
FieldMessageText.UNK_207 = 0x0207
FieldMessageText.UNK_208 = 0x0208
FieldMessageText.COLOR = 0xFF00
FieldMessageText.SIZE = 0xFF01
FieldMessageText.UNK_FF02 = 0xFF02

-- The marker name registry: family bases for STRVAR families, plain codes
-- otherwise. Names are exactly what the marker syntax accepts and must stay in
-- sync with data/reference/hgss/charmap.lua controlNames (verified by the
-- importer tests).
FieldMessageText.controlNames = {
  [0x0100] = "STRVAR_1",
  [0x0300] = "STRVAR_3",
  [0x0400] = "STRVAR_4",
  [0x3400] = "STRVAR_34",
  [0x0200] = "YESNO",
  [0x0201] = "PAUSE",
  [0x0202] = "WAIT",
  [0x0203] = "CURSOR_X",
  [0x0204] = "CURSOR_Y",
  [0x0205] = "ALN_CENTER",
  [0x0206] = "ALN_RIGHT",
  [0x0207] = "UNK_207",
  [0x0208] = "UNK_208",
  [0xFF00] = "COLOR",
  [0xFF01] = "SIZE",
  [0xFF02] = "UNK_FF02",
}

local namesByCode = FieldMessageText.controlNames
local codesByName = {}
for code, name in pairs(namesByCode) do
  codesByName[name] = code
end
FieldMessageText.namesByCode = namesByCode
FieldMessageText.codesByName = codesByName

-- Marker grammar (the published text form):
--   text    := segment*
--   segment := glyph* | "\n" | "\r" | "\f" | marker
--   marker  := "{" name (" " value ("," value)*)? "}"
--            | "{" "CTRL" " " 0xXXXX (" " value ("," value)*)? "}"
--   name    := STRVAR_1 | STRVAR_3 | STRVAR_4 | STRVAR_34 | YESNO | PAUSE
--            | WAIT | CURSOR_X | CURSOR_Y | ALN_CENTER | ALN_RIGHT | COLOR
--            | SIZE | TRNAME
--   value   := decimal integer
-- A STRVAR marker's first value is its field selector (low byte of the code).

-- True for the STRVAR families declared by MsgArray_ControlCodeIsStrVar
-- (src/string_control_code.c): 0x0100..0x01FF, 0x0300..0x03FF,
-- 0x0400..0x04FF, 0x3400..0x34FF.
function FieldMessageText.isStrvarFamily(control)
  local family = math.floor(control / 256) * 256
  return family == 0x0100 or family == 0x0300 or family == 0x0400 or family == 0x3400
end

-- Token kind for a control code: substitution, style, wait, or
-- unsupported_control. Matches the import tokenizer's classification.
function FieldMessageText.controlKind(control)
  if FieldMessageText.isStrvarFamily(control) then
    return "substitution"
  end
  if control == FieldMessageText.COLOR or control == FieldMessageText.SIZE or control == FieldMessageText.UNK_FF02 then
    return "style"
  end
  if control == FieldMessageText.PAUSE or control == FieldMessageText.WAIT then
    return "wait"
  end
  return "unsupported_control"
end

-- Marker name for a control code (nil for unknown codes).
function FieldMessageText.controlName(control)
  if FieldMessageText.isStrvarFamily(control) then
    return namesByCode[math.floor(control / 256) * 256]
  end
  return namesByCode[control]
end

-- Builds one marker string: marker(control, ...args). A STRVAR control
-- includes its field selector as the first value.
function FieldMessageText.marker(control, ...)
  local args = { ... }
  local label = FieldMessageText.controlName(control) or string.format("CTRL 0x%04X", control)
  local values = {}
  if FieldMessageText.isStrvarFamily(control) then
    values[#values + 1] = tostring(control % 256)
  end
  for _, arg in ipairs(args) do
    values[#values + 1] = tostring(arg)
  end
  if #values > 0 then
    return "{" .. label .. " " .. table.concat(values, ", ") .. "}"
  end
  return "{" .. label .. "}"
end

-- Renders a token stream to its display text. EOS is terminal: rendering
-- stops at the first EOS and later tokens are ignored. Substitution/style/
-- wait/unsupported tokens before EOS render their markers so no control is
-- silently dropped from the text form.
function FieldMessageText.tokensToText(tokens)
  assert(type(tokens) == "table", "tokensToText requires a token stream")
  local out = {}
  for _, token in ipairs(tokens) do
    if token.kind == "eos" then
      break
    elseif token.kind == "glyph" then
      out[#out + 1] = token.text
    elseif token.kind == "line_break" then
      out[#out + 1] = "\n"
    elseif token.kind == "prompt_break" then
      out[#out + 1] = "\r"
    elseif token.kind == "page_break" then
      out[#out + 1] = "\f"
    elseif token.kind == "substitution" and token.control == FieldMessageText.TRNAME then
      out[#out + 1] = "{TRNAME}"
    else
      out[#out + 1] = FieldMessageText.marker(token.control, unpack(token.args or {}))
    end
  end
  return table.concat(out)
end

local function parseBody(text, fontDef, opts)
  opts = opts or {}
  local tokens = {}
  local position = 1

  local function pushGlyphs(char)
    local code = fontDef.charmap[char]
    if not code then
      Errors.raise(
        "MESSAGE_SUBSTITUTION_UNRESOLVED",
        "character " .. string.format("%q", char) .. " has no field glyph",
        { character = char, index = position }
      )
    end
    tokens[#tokens + 1] = {
      kind = "glyph",
      code = code,
      text = char,
      raw = { code },
    }
  end

  local function parseMarker()
    -- position points at the '{'; find the closing brace.
    local close = text:find("}", position, true)
    if not close then
      Errors.raise(
        "MESSAGE_MARKER_INVALID",
        "unterminated marker at index " .. position,
        { index = position, marker = text:sub(position) }
      )
    end
    local body = text:sub(position + 1, close - 1)
    position = close + 1
    local name, rest = body:match("^([^%s]+)%s*(.*)$")
    if not name or name == "" then
      Errors.raise(
        "MESSAGE_MARKER_INVALID",
        "empty marker at index " .. position,
        { index = position, marker = text:sub(position - 1, close) }
      )
    end
    -- Values are comma- or space-separated: "{STRVAR_1 3, 0, 0}" and
    -- "{CTRL 0x0707 9}" both parse.
    local values = {}
    if rest ~= "" then
      for value in rest:gmatch("[^,%s]+") do
        local trimmed = value:match("^%s*(.-)%s*$")
        local number = tonumber(trimmed)
        if not number or number < 0 or number > 65535 or number % 1 ~= 0 then
          Errors.raise(
            "MESSAGE_MARKER_INVALID",
            "marker argument " .. string.format("%q", trimmed) .. " is not a u16",
            { index = position, argument = trimmed, marker = body }
          )
        end
        values[#values + 1] = number
      end
    end

    local control
    local args = values
    if name == "CTRL" then
      local code = body:match("^CTRL%s+0x(%x%x%x%x)")
      if not code then
        Errors.raise(
          "MESSAGE_MARKER_INVALID",
          "CTRL marker needs a 0xXXXX code: " .. body,
          { index = position, marker = body }
        )
      end
      control = tonumber(code, 16)
      args = {}
      for i = 2, #values do
        args[#args + 1] = values[i]
      end
    elseif name == "TRNAME" then
      if #values > 0 then
        Errors.raise(
          "MESSAGE_MARKER_INVALID",
          "TRNAME takes no arguments: " .. body,
          { index = position, marker = body }
        )
      end
      control = FieldMessageText.TRNAME
    else
      local base = codesByName[name]
      if not base then
        Errors.raise(
          "MESSAGE_MARKER_INVALID",
          "unknown marker name " .. string.format("%q", name),
          { index = position, name = name, marker = body }
        )
      end
      control = base
      if FieldMessageText.isStrvarFamily(base) then
        if #values == 0 then
          Errors.raise(
            "MESSAGE_MARKER_INVALID",
            "STRVAR marker needs a field selector: " .. body,
            { index = position, marker = body }
          )
        end
        local field = table.remove(values, 1)
        if field > 255 then
          Errors.raise(
            "MESSAGE_MARKER_INVALID",
            "STRVAR field selector is not a byte: " .. body,
            { index = position, marker = body }
          )
        end
        control = base + field
      end
    end

    local raw = { FieldMessageText.EXT_CTRL_CODE_BEGIN, control, #args }
    for _, arg in ipairs(args) do
      raw[#raw + 1] = arg
    end
    tokens[#tokens + 1] = {
      kind = FieldMessageText.controlKind(control),
      control = control,
      name = FieldMessageText.controlName(control),
      args = args,
      raw = raw,
    }
  end

  while position <= #text do
    local char = text:sub(position, position)
    if char == "{" then
      parseMarker()
    elseif char == "\n" then
      tokens[#tokens + 1] = { kind = "line_break", raw = { FieldMessageText.CHAR_LF } }
      position = position + 1
    elseif char == "\r" then
      tokens[#tokens + 1] = { kind = "prompt_break", raw = { FieldMessageText.PROMPT_BREAK } }
      position = position + 1
    elseif char == "\f" then
      tokens[#tokens + 1] = { kind = "page_break", raw = { FieldMessageText.PAGE_BREAK } }
      position = position + 1
    else
      -- One UTF-8 sequence: leading byte determines the width.
      local byte = text:byte(position)
      local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
      pushGlyphs(text:sub(position, math.min(position + width - 1, #text)))
      position = position + width
    end
  end

  if opts.eos ~= false then
    tokens[#tokens + 1] = { kind = "eos", raw = { FieldMessageText.EOS } }
  end
  return tokens
end

local function parseEntry(text, fontDef, opts)
  local ok, result = pcall(parseBody, text, fontDef, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- Parses marker text back into a lossless token stream. Glyphs resolve
-- through fontDef.charmap (the font definition's text -> code metadata); an
-- eos token is appended unless opts.eos is false. Returns (tokens | nil, err)
-- with MESSAGE_MARKER_INVALID on malformed markers and
-- MESSAGE_SUBSTITUTION_UNRESOLVED on characters without a glyph.
function FieldMessageText.parse(text, fontDef, opts)
  assert(type(text) == "string", "parse requires marker text")
  assert(
    type(fontDef) == "table" and type(fontDef.charmap) == "table",
    "parse requires a font definition with charmap metadata"
  )
  return parseEntry(text, fontDef, opts)
end

return FieldMessageText
