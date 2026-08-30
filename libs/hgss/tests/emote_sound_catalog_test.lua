-- Automatic emote sound stays exact-or-silent: a catalog entry proven from
-- authoritative source/resource evidence plays its exact effect once at the
-- movement action's start boundary; any unproven semantic emote kind plays
-- nothing. There is no guessed/default/fallback effect. This exercises the
-- catalog contract through the same call-site pattern the movement action
-- lifecycle uses (lookup once, play only when non-nil).

local Assert = require("tests.support.Assert")
local EmoteSoundCatalog = require("libs.hgss.src.script.EmoteSoundCatalog")

local T = {}

local function fakeAudio()
  return {
    calls = {},
    play = function(self, effectId)
      self.calls[#self.calls + 1] = effectId
    end,
  }
end

-- Mirrors the normative action-start call site: look the semantic kind up
-- once, and call the audio service only when the catalog proves a mapping.
local function beginEmoteAction(catalog, audio, kind)
  local effectId = catalog:effectFor(kind)
  if effectId ~= nil then
    audio:play(effectId)
  end
end

function T.a_proven_mapping_plays_its_exact_effect_exactly_once_and_an_unmapped_kind_plays_nothing()
  local catalog = EmoteSoundCatalog.new({ exclamation = "SEQ_SE_DP_KAIDAN2" })
  local audio = fakeAudio()

  beginEmoteAction(catalog, audio, "exclamation")
  Assert.equal(#audio.calls, 1, "a proven mapping must play exactly once at the action-start boundary")
  Assert.equal(audio.calls[1], "SEQ_SE_DP_KAIDAN2", "the exact catalog effect id must play, never a guessed one")

  beginEmoteAction(catalog, audio, "question")
  Assert.equal(#audio.calls, 1, "an unmapped emote kind must never produce an automatic audio call")

  Assert.isNil(catalog:effectFor("question"), "an unmapped kind resolves to nil, never a fallback effect")
end

function T.repeated_lookups_of_an_unmapped_kind_stay_silent_and_deterministic()
  local catalog = EmoteSoundCatalog.new({})
  local audio = fakeAudio()
  for _ = 1, 4 do
    beginEmoteAction(catalog, audio, "exclamation")
  end
  Assert.equal(#audio.calls, 0, "repeated lookups of an unproven kind must never call audio")
end

return { tests = T }
