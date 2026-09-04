-- Unit coverage for Oak's immutable bank-219 template and substitution boundary.

local Assert = require("tests.support.Assert")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local OakIntroMessages = require("game.hgss.src.newgame.OakIntroMessages")

local T = {}

local FONT = {
  charmap = {
    G = 1,
    O = 2,
    L = 3,
    D = 4,
    ["?"] = 5,
    Y = 6,
    E = 7,
    S = 8,
    N = 9,
    A = 10,
    M = 11,
    o = 12,
    [" "] = 13,
  },
}

local function template(id, text)
  return {
    bankId = 219,
    messageId = id,
    text = text,
    tokens = assert(FieldMessageText.parse(text, FONT)),
  }
end

local function formatter()
  return OakIntroMessages.new({
    fontDef = FONT,
    templates = {
      nameConfirm = template(41, "NAME {STRVAR_1 3, 0, 0}?"),
      final = template(43, "{STRVAR_1 3, 0, 0}"),
      ["choice.yes"] = template(47, "Y"),
      ["choice.no"] = template(48, "N"),
    },
  })
end

function T.formats_the_expected_player_name_without_mutating_the_template()
  local templates = {
    nameConfirm = template(41, "NAME {STRVAR_1 3, 0, 0}?"),
  }
  local before = templates.nameConfirm.tokens
  local message = OakIntroMessages.new({ fontDef = FONT, templates = templates }):format("nameConfirm", {
    playerName = "GOLD",
  })
  Assert.isFalse(message.hadUnresolvedSubstitutions)
  Assert.equal(message.text, "NAME GOLD?")
  Assert.equal(templates.nameConfirm.tokens, before)
  Assert.equal(templates.nameConfirm.tokens[6].kind, "substitution")
end

function T.rejects_an_unexpected_or_malformed_substitution()
  local malformed = OakIntroMessages.new({
    fontDef = FONT,
    templates = { nameConfirm = template(41, "{STRVAR_1 4, 0, 0}") },
  })
  local ok = pcall(function()
    malformed:format("nameConfirm", { playerName = "GOLD" })
  end)
  Assert.isFalse(ok)
end

function T.uses_source_choice_labels()
  local labels = formatter():choiceLabels()
  Assert.equal(labels[0], "Y")
  Assert.equal(labels[1], "N")
end

return { tests = T }
