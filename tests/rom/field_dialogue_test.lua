-- ROM-conformance dialogue facts: the real cached font definition and bank
-- messages lay out and advance deterministically through the pure dialogue
-- layers (provider -> format -> layout -> controller) without any LÖVE
-- graphics. Structural facts only; no retail text is
-- asserted or printed.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldFontCache = require("libs.assets.src.FieldFontCache")

local T = {}

---@param version string
---@return FieldFontDef
local function fontDef(version)
  local def = assert(CacheFs.forVersion(version):loadLua("data/generated/field/font/font-0.lua"))
  assert(def.schema == FieldFontCache.SCHEMA, "field font cache is cold")
  return def --[[@as FieldFontDef]]
end

-- Runs one real bank message through format -> layout -> controller and
-- drives it to completion with Action. Returns the page count and the
-- completion result.
local function runMessage(version, bankId, messageId)
  local def = fontDef(version)
  local cache = CacheFs.forVersion(version)
  local provider = assert(FieldMessageProvider.new(cache))
  local bank = provider:acquireBank(bankId)
  assert(bank, "message bank cache is cold")
  local template = assert(provider:get(bankId, messageId))
  local formatted = provider:format(template, { playerName = "GOLD" }, {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
    end,
  })
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local layout = function(message)
    return DialogueLayout.layout(
      message.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
  end
  local first = layout(formatted)
  local second = layout(formatted)
  Assert.deepEqual(first, second, "layout is deterministic for the same tokens")

  local controller = FieldDialogueController.new({ layout = layout })
  local completed = nil
  local handle = controller:open({
    id = string.format("target-%d-%d", bankId, messageId),
    message = formatted,
    allowCancel = false,
    metadata = { bankId = bankId, messageId = messageId },
  })
  handle:onComplete(function(result)
    completed = result
  end)
  local ticks = 0
  while controller:isModal() and ticks < 500 do
    controller:step({ actionPressed = true })
    ticks = ticks + 1
  end
  Assert.isTrue(ticks < 500, "target message reaches completion within 500 ticks")
  assert(completed, "completion result required")
  provider:releaseBank(bankId)
  return #first.pages, completed
end

function T.target_fixture_messages_lay_out_and_close(_, version)
  local cases = {
    { bankId = 542, messageId = 1 },
    { bankId = 543, messageId = 5 },
    { bankId = 543, messageId = 14 },
    { bankId = 543, messageId = 18 },
    { bankId = 543, messageId = 93 },
    { bankId = 543, messageId = 94 },
    { bankId = 543, messageId = 95 },
    { bankId = 543, messageId = 96 },
    { bankId = 543, messageId = 97 },
  }
  for _, spec in ipairs(cases) do
    local pages, result = runMessage(version, spec.bankId, spec.messageId)
    Assert.isTrue(
      pages >= 1,
      string.format("bank %d message %d produces at least one page", spec.bankId, spec.messageId)
    )
    Assert.equal(result.kind, "complete")
    Assert.equal(result.requestId, string.format("target-%d-%d", spec.bankId, spec.messageId))
  end
end

function T.target_lines_stay_inside_the_reference_text_width(_, version)
  local def = fontDef(version)
  local cache = CacheFs.forVersion(version)
  local provider = assert(FieldMessageProvider.new(cache))
  local metrics = FieldDialogueTheme.fontMetrics(def)
  local widths = {}
  assert(provider:acquireBank(543))
  for messageId = 0, 105 do
    local template = assert(provider:get(543, messageId))
    local formatted = provider:format(template, { playerName = "GOLD" }, {
      [0x0103] = function()
        return FieldMessageProvider.asciiGlyphTokens("GOLD", def)
      end,
    })
    local layout = DialogueLayout.layout(
      formatted.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
    local warnedWidths = {}
    for _, warning in ipairs(layout.warnings) do
      if warning.kind == "overwide" then
        warnedWidths[warning.width] = true
      end
    end
    for _, page in ipairs(layout.pages) do
      for _, line in ipairs(page.lines) do
        widths[#widths + 1] = line.width
        -- Only glyph advance contributes to line width, and every over-wide
        -- line is traced as an overwide warning.
        Assert.isTrue(
          line.width <= FieldDialogueTheme.textWidth or warnedWidths[line.width] == true,
          string.format("bank 543 message %d line %d exceeds the text width untraced", messageId, line.width)
        )
      end
    end
  end
  Assert.isTrue(#widths > 100, "every bank 543 message lays out")
  provider:releaseBank(543)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
