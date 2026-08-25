-- Utf8Glyphs contract tests: the tiny pure glyph iterator shared by player
-- name validation, text measurement, and rendering, so no consumer ever
-- iterates text bytes again. The leading byte determines the sequence width
-- (1..4), a truncated final sequence yields the remaining bytes, and the
-- iteration yields every glyph exactly once.

local Assert = require("tests.support.Assert")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local T = {}

local function glyphs(text)
  local out = {} ---@type string[]
  local iterator = Utf8Glyphs.iter(text)
  for glyph in iterator do
    out[#out + 1] = glyph
  end
  return out
end

function T.ascii_text_yields_each_byte_as_one_glyph()
  Assert.deepEqual(glyphs("GOLD"), { "G", "O", "L", "D" })
end

function T.multibyte_sequences_yield_one_glyph_each()
  -- É = U+00C9 (two bytes), € = U+20AC (three bytes), U+1F434 (four bytes).
  Assert.deepEqual(glyphs("\195\137"), { "\195\137" })
  Assert.deepEqual(glyphs("\226\130\172"), { "\226\130\172" })
  Assert.deepEqual(glyphs("\240\159\144\180"), { "\240\159\144\180" })
end

function T.mixed_text_yields_every_glyph_in_order()
  Assert.deepEqual(glyphs("\195\137lise"), { "\195\137", "l", "i", "s", "e" })
  Assert.equal(
    #glyphs("\195\137\195\137\195\137\195\137\195\137"),
    5,
    "five two-byte glyphs are five iterations, not ten"
  )
end

function T.empty_text_yields_nothing()
  Assert.deepEqual(glyphs(""), {})
end

function T.truncated_final_sequence_yields_the_remaining_bytes()
  Assert.deepEqual(glyphs("A\195"), { "A", "\195" })
  Assert.deepEqual(glyphs("\195\169"), { "\195\169" })
end

return { tests = T }
