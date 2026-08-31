-- Production Oak composition tests cover generated semantic inputs and the
-- host-owned randomness boundary without embedding generated dialogue.

local Assert = require("tests.support.Assert")
local OakIntroComposition = require("game.hgss.src.newgame.OakIntroComposition")

local T = { tests = {} }

function T.tests.message_ids_have_one_semantic_mapping()
  local messages = OakIntroComposition.messageKeys({
    [1] = { text = "morning" },
    [2] = { text = "day" },
    [3] = { text = "evening" },
    [4] = { text = "night" },
    [5] = { text = "midnight" },
    [6] = { text = "welcome" },
    [34] = { text = "inhabited" },
    [35] = { text = "alongside" },
    [36] = { text = "yourself" },
    [37] = { text = "gender" },
    [38] = { text = "male" },
    [39] = { text = "female" },
    [40] = { text = "name" },
    [41] = { text = "male-name" },
    [42] = { text = "female-name" },
    [43] = { text = "final" },
  })

  Assert.equal(messages["greeting.morning"].text, "morning")
  Assert.equal(messages["greeting.day"].text, "day")
  Assert.equal(messages["greeting.evening"].text, "evening")
  Assert.equal(messages["greeting.night"].text, "night")
  Assert.equal(messages["greeting.midnight"].text, "midnight")
  Assert.equal(messages["oak.welcome"].text, "welcome")
  Assert.equal(messages["oak.world_inhabited"].text, "inhabited")
  Assert.equal(messages["oak.live_alongside"].text, "alongside")
  Assert.equal(messages["oak.tell_about_yourself"].text, "yourself")
  Assert.equal(messages["profile.gender_question"].text, "gender")
  Assert.equal(messages["profile.gender_confirm.male"].text, "male")
  Assert.equal(messages["profile.gender_confirm.female"].text, "female")
  Assert.equal(messages["profile.name_prompt"].text, "name")
  Assert.equal(messages["profile.name_confirm.male"].text, "male-name")
  Assert.equal(messages["profile.name_confirm.female"].text, "female-name")
  Assert.equal(messages["profile.final"].text, "final")
end

function T.tests.random_u32_provider_returns_nonconstant_uint32_values()
  local draws = { 0x1234, 0x5678 }
  local random = OakIntroComposition.randomU32({
    random = function()
      return table.remove(draws, 1)
    end,
  })
  local value = random()
  Assert.equal(value, 0x12345678)
  Assert.isTrue(value >= 0 and value <= 0xFFFFFFFF)
end

return T
