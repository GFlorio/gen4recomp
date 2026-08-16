-- ROM-conformance facts for the message/font derived classes, verified against
-- the imported ROM. Asserts only non-copyright structural facts: bank counts,
-- control census, glyph coverage, map-header associations, and font geometry.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldMessageBank = require("romdump.src.digest.FieldMessageBank")
local FieldMessageTokenizer = require("romdump.src.digest.FieldMessageTokenizer")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local FieldMessageText = require("libs.assets.src.FieldMessageText")
local FieldMessageCache = require("libs.assets.src.FieldMessageCache")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldMessages = require("romdump.src.config.FieldMessages")
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldFontDecoder = require("romdump.src.digest.FieldFontDecoder")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local charmap = require("romdump.src.reference.hgss.charmap")
local MenuProtocol = require("libs.assets.src.MenuProtocol")

local T = {}

local function sourceFacts(romFs)
  local messages = assert(romFs:openNarc("messages"))
  local font = assert(romFs:openNarc("font"))
  return messages, font
end

function T.target_bank_counts_and_decryption_vectors(romFs)
  local messages = assert(romFs:openNarc("messages"))
  for _, spec in ipairs({
    { bankId = 542, count = 38, firstMessage = { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE } },
    { bankId = 543, count = 106 },
  }) do
    local member = messages:readMember(spec.bankId)
    local bank = assert(FieldMessageBank.decode(member, { label = "msg-" .. spec.bankId }))
    Assert.equal(bank.messageCount, spec.count)
    Assert.equal(bank.tableEnd, 4 + spec.count * 8)
    if spec.firstMessage then
      Assert.deepEqual(bank.messages[1].raw[1] and {
        bank.messages[1].raw[1],
        bank.messages[1].raw[2],
        bank.messages[1].raw[3],
        bank.messages[1].raw[4],
        bank.messages[1].raw[5],
      }, spec.firstMessage)
    end
  end
end

function T.selected_bank_control_census_is_stable(romFs)
  -- Inventory the control census of every bank the FieldMessages manifest
  -- selects, reported as semantic kind + control code. YESNO (0x0200) is the
  -- focus-indicator control; CURSOR_X (0x0203) and ALN_CENTER (0x0205) are
  -- selected-bank controls that remain unsupported, so their presence in the
  -- census is expected but their playback is not.
  local messages = assert(romFs:openNarc("messages"))
  local signatures = {}
  for _, bankId in ipairs(FieldMessages.banks) do
    local bank = assert(FieldMessageBank.decode(messages:readMember(bankId), {}))
    for _, message in ipairs(bank.messages) do
      local tokens = assert(FieldMessageTokenizer.tokenize(message.raw, charmap, {}))
      for _, token in ipairs(tokens) do
        if token.kind ~= "glyph" and token.kind ~= "eos" then
          local key = token.kind .. ":" .. string.format("%04x", token.control or 0)
          signatures[key] = true
        end
      end
    end
  end
  local expected = {
    ["line_break:0000"] = true,
    ["prompt_break:0000"] = true,
    ["page_break:0000"] = true,
    ["style:ff00"] = true,
    ["substitution:0100"] = true,
    ["substitution:0101"] = true,
    ["substitution:0102"] = true,
    ["substitution:0103"] = true,
    ["substitution:0132"] = true,
    ["substitution:0134"] = true,
    ["substitution:0135"] = true,
    ["substitution:0136"] = true,
    ["substitution:0137"] = true,
    ["focus_indicator:0200"] = true,
    ["unsupported_control:0203"] = true,
    ["unsupported_control:0205"] = true,
  }
  for key in pairs(expected) do
    Assert.isTrue(signatures[key], "missing control signature " .. key)
  end
  -- No unknown families in the selected banks: every signature is accounted
  -- for.
  for key in pairs(signatures) do
    Assert.isTrue(expected[key], "unexpected control signature " .. key)
  end
end

function T.known_yesno_and_color_messages_carry_the_expected_controls(romFs)
  -- Known target-message control facts for bank 543, verified from the raw
  -- ROM code units: messages 8/9/27/92 end with a YESNO field 0, and messages
  -- 79/80 carry the COLOR 1 -> 0 transition around the highlighted span.
  -- Structural facts only; no retail message text is asserted.
  local messages = assert(romFs:openNarc("messages"))
  local bank = assert(FieldMessageBank.decode(messages:readMember(543), {}))
  local function controlsOf(messageId)
    local tokens = assert(FieldMessageTokenizer.tokenize(bank.messages[messageId + 1].raw, charmap, {}))
    local controls = {}
    for _, token in ipairs(tokens) do
      if token.kind ~= "glyph" and token.kind ~= "eos" then
        controls[#controls + 1] = token
      end
    end
    return controls
  end
  for _, messageId in ipairs({ 8, 9, 27, 92 }) do
    local yesno = {}
    for _, token in ipairs(controlsOf(messageId)) do
      if token.control == FieldMessageText.YESNO then
        yesno[#yesno + 1] = token
      end
    end
    Assert.equal(#yesno, 1, "bank 543 message " .. messageId .. " has exactly one YESNO")
    Assert.equal(yesno[1].kind, "focus_indicator")
    Assert.equal(yesno[1].name, "YESNO")
    Assert.deepEqual(yesno[1].args, { 0 })
  end
  for _, messageId in ipairs({ 79, 80 }) do
    local colorArgs = {}
    for _, token in ipairs(controlsOf(messageId)) do
      if token.control == FieldMessageText.COLOR then
        colorArgs[#colorArgs + 1] = token.args[1]
      end
    end
    Assert.equal(#colorArgs, 2, "bank 543 message " .. messageId .. " has two COLOR controls")
    Assert.equal(colorArgs[1], 1, "message " .. messageId .. " opens the color span at 1")
    Assert.equal(colorArgs[2], 0, "message " .. messageId .. " closes the color span back to 0")
  end
end

function T.known_target_messages_format_with_prepared_tokens(romFs, version)
  -- The known target messages must pass through the actual provider
  -- formatting path (compiled bank cache -> template -> substitution
  -- resolution -> prepared tokens) without an unsupported-control fault:
  -- glyphs carry their effective colorIndex, and the indicator survives with
  -- field 0. A layout/controller-only test cannot prove this: the provider is
  -- the playback boundary that validates and prepares printer controls.
  local cache = CacheFs.forVersion(version)
  local def = assert(cache:loadLua("data/generated/field/font/font-0.lua"))
  local provider = assert(FieldMessageProvider.new(cache))
  provider:acquireBank(543)
  local resolvers = {
    [0x0100] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
    [0x0101] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
  }
  for _, messageId in ipairs({ 8, 9, 27, 92 }) do
    local template = assert(provider:get(543, messageId))
    local formatted = assert(provider:format(template, { playerName = "GOLD" }, resolvers))
    Assert.isFalse(formatted.hadUnresolvedSubstitutions)
    local indicator
    for _, token in ipairs(formatted.tokens) do
      if token.kind == "glyph" then
        Assert.equal(token.colorIndex, 0, "bank 543 message " .. messageId .. " glyph stays default color")
      elseif token.control == FieldMessageText.YESNO then
        indicator = token
      end
    end
    Assert.notNil(indicator, "message " .. messageId .. " keeps its indicator token")
    Assert.equal(indicator.kind, "focus_indicator")
    Assert.equal(indicator.control, FieldMessageText.YESNO)
    Assert.deepEqual(indicator.args, { 0 })
  end
  for _, messageId in ipairs({ 79, 80 }) do
    local template = assert(provider:get(543, messageId))
    local formatted = assert(provider:format(template, { playerName = "GOLD" }, resolvers))
    Assert.isFalse(formatted.hadUnresolvedSubstitutions)
    local current = 0
    local highlighted = 0
    local afterSpan = 0
    for _, token in ipairs(formatted.tokens) do
      if token.kind == "style" and token.control == FieldMessageText.COLOR then
        current = token.args[1]
      elseif token.kind == "glyph" then
        Assert.equal(token.colorIndex, current, "message " .. messageId .. " glyph carries the active color")
        if current == 1 then
          highlighted = highlighted + 1
        elseif highlighted > 0 then
          afterSpan = afterSpan + 1
        end
      end
    end
    Assert.isTrue(highlighted > 0, "message " .. messageId .. " highlights its color span")
    Assert.isTrue(afterSpan > 0, "message " .. messageId .. " returns to default color after the span")
  end
  provider:releaseBank(543)
end

function T.target_glyph_set_resolves_in_the_font(romFs)
  local messages = assert(romFs:openNarc("messages"))
  local font = assert(FieldFontDecoder.decodeMember(assert(romFs:openNarc("font")):readMember(0)))
  -- Collect glyph codes from the token streams: control arguments in the raw
  -- units are data, not characters.
  local glyphs = {}
  for _, bankId in ipairs({ 542, 543 }) do
    local bank = assert(FieldMessageBank.decode(messages:readMember(bankId), {}))
    for _, message in ipairs(bank.messages) do
      local tokens = assert(FieldMessageTokenizer.tokenize(message.raw, charmap, {}))
      for _, token in ipairs(tokens) do
        if token.kind == "glyph" then
          glyphs[token.code] = true
        end
      end
    end
  end
  local glyphCount = 0
  for _ in pairs(glyphs) do
    glyphCount = glyphCount + 1
  end
  Assert.isTrue(glyphCount > 60)
  for code in pairs(glyphs) do
    Assert.notNil(charmap.glyphs[code], string.format("unmapped glyph 0x%04X", code))
    Assert.isTrue(code <= font.numGlyphs, string.format("glyph 0x%04X beyond font", code))
  end
end

function T.map_header_bank_associations_are_emitted(romFs)
  local associations = {}
  for _, mapId in ipairs({ 60, 61 }) do
    local field = assert(FieldMapDataCompiler.compile(romFs, mapId)).field
    associations[mapId] = field.messageBankId
  end
  Assert.equal(associations[60], 542)
  Assert.equal(associations[61], 543)
end

function T.font_geometry_matches_the_rom_member(romFs)
  local font = assert(FieldFontDecoder.decodeMember(assert(romFs:openNarc("font")):readMember(0)))
  Assert.equal(font.numGlyphs, 509)
  Assert.equal(font.fixedWidth, 16)
  Assert.equal(font.fixedHeight, 16)
  Assert.equal(font.tileColumns, 2)
  Assert.equal(font.tileRows, 2)
  Assert.equal(font.glyphSize, 64)
  Assert.equal(font.glyphWidth(0x12B - 1), 6) -- 'A'
  Assert.equal(font.glyphWidth(0x1DE - 1), 4) -- space

  -- 'A' (0x12B) has the expected ink silhouette: an apex row, a crossbar row,
  -- and vertical legs; verified by decoding glyph pixels from ROM data.
  local glyph = font.glyphPixels(0x12B - 1)
  local inkRows = {}
  for y = 1, 16 do
    local count = 0
    for x = 1, 16 do
      if glyph.values[y][x] ~= 0 then
        count = count + 1
      end
    end
    inkRows[y] = count
  end
  Assert.isTrue(inkRows[4] > 0, "apex row must be inked")
  Assert.isTrue(inkRows[8] > 2, "crossbar row must be wide")
  Assert.isTrue(inkRows[13] > 0, "legs must reach the baseline")
end

function T.artifact_text_round_trips_through_marker_parse(romFs, version)
  -- The published text form is canonical: parsing a bank message's text with
  -- the compiled font charmap and rendering it back yields the same string.
  local messages = assert(romFs:openNarc("messages"))
  local fontDef = {
    charmap = assert(CacheFs.forVersion(version):loadLua("data/generated/field/font/font-0.lua")).charmap,
  }
  local samples = { [542] = { 0, 1, 4, 5 }, [543] = { 0, 5, 14, 18, 93, 97 } }
  for bankId, messageIds in pairs(samples) do
    local bank = assert(FieldMessageBank.decode(messages:readMember(bankId), {}))
    for _, messageId in ipairs(messageIds) do
      local tokens = assert(FieldMessageTokenizer.tokenize(bank.messages[messageId + 1].raw, charmap, {}))
      local text = FieldMessageText.tokensToText(tokens)
      local reparsed = assert(FieldMessageText.parse(text, fontDef))
      Assert.equal(
        FieldMessageText.tokensToText(reparsed),
        text,
        string.format("bank %d message %d round trip", bankId, messageId)
      )
    end
  end
end

function T.font_palette_matches_the_rom_member(romFs)
  local palette = assert(FieldFontDecoder.decodePalette(assert(romFs:openNarc("font")):readMember(7)))
  Assert.equal(palette.colorCount, 16)
  Assert.equal(palette.depth, 3)
  -- Slot 1 = foreground ink, slot 2 = shadow, slot 15 = white background.
  local fg = palette.colors[2]
  Assert.isTrue(fg.r < 120 and fg.g < 120 and fg.b < 120, "fg must be dark")
  Assert.deepEqual(palette.colors[16], { r = 255, g = 255, b = 255 })
end

function T.standard_menu_bank_holds_the_vanilla_list_menu_ids(romFs)
  -- Source-faithful 749 menus resolve item ids against the standard list-menu
  -- bank (MenuProtocol.STANDARD_MESSAGE_BANK). The scr_seq corpus references
  -- ids up to 475 (member 3's mart menus use 321/322/323, the info menu 324),
  -- so the standard bank must cover every id the runtime will resolve.
  local messages = assert(romFs:openNarc("messages"))
  local menu = assert(
    FieldMessageBank.decode(messages:readMember(MenuProtocol.STANDARD_MESSAGE_BANK), {}),
    "standard menu bank must exist"
  )
  for _, id in ipairs({ 321, 322, 323, 324, 475 }) do
    Assert.isTrue(menu.messages[id + 1] ~= nil, "standard menu bank must hold list-menu message " .. tostring(id))
  end
end

function T.compiled_cache_artifacts_are_ready_and_stable(romFs, version)
  local cache = CacheFs.forVersion(version)
  local messages = assert(romFs:openNarc("messages"))
  local font = assert(romFs:openNarc("font"))
  local function archiveSha(alias)
    local info = assert(romFs:resolvedNarc(alias))
    return require("romdump.src.digest.Hashing").sha1hex(assert(romFs:read(info.fileId)))
  end
  local function memberSha(alias, memberId)
    return require("romdump.src.digest.Hashing").sha1hex(assert(assert(romFs:openNarc(alias)):readMember(memberId)))
  end
  -- Deterministic markers: compilers run with real hashes, so the marker
  -- depends only on ROM contents and the checked-in compiler versions.
  local messageBundle = assert(FieldMessageCompiler.compile(romFs))
  Assert.equal(messageBundle.index.bankIds[1], 542)
  Assert.equal(messageBundle.index.bankIds[2], 543)
  local menuBankSelected = false
  for _, bankId in ipairs(messageBundle.index.bankIds) do
    if bankId == MenuProtocol.STANDARD_MESSAGE_BANK then
      menuBankSelected = true
    end
  end
  Assert.isTrue(menuBankSelected, "the standard menu bank must be selected for the derived cache")
  Assert.isTrue(FieldMessageCache.isReady(cache, messageBundle.marker))
  Assert.equal(FieldMessageCache.bankPath(542), "data/generated/field/messages/banks/0542.lua")
  local fontBundle = assert(FieldFontCompiler.compile(romFs))
  Assert.isTrue(require("romdump.src.digest.FieldFontCacheWriter").isReady(cache, 0, fontBundle.marker))
  Assert.equal(fontBundle.font.glyphCount, 509)
  Assert.isNil(fontBundle.font.source)
  Assert.equal(fontBundle.dependencies.glyphMemberSha1, memberSha("font", 0))
  Assert.equal(fontBundle.dependencies.paletteMemberSha1, memberSha("font", 7))
  Assert.equal(messageBundle.dependencies.messageNarc.sha1, archiveSha("messages"))
end

return require("tests.rom.support.RomSuite").fromFacts(T)
