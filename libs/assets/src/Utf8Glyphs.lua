-- Iterates the UTF-8 glyphs of a string: the leading byte determines the
-- sequence width (1..4 bytes), matching the generated field font's text
-- iteration, and a truncated final sequence yields the remaining bytes. The
-- one tiny shared iterator for player-name validation, text measurement, and
-- rendering, so no consumer ever iterates text bytes again. Pure module: no
-- love dependency, no generalized Unicode library.

local Utf8Glyphs = {}

-- The one iterator: yields every full glyph substring in order.
---@param text string
---@return fun(): string?
function Utf8Glyphs.iter(text)
  assert(type(text) == "string", "Utf8Glyphs.iter requires a string")
  local position = 1
  return function()
    if position > #text then
      return nil
    end
    local byte = text:byte(position)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    local glyph = text:sub(position, math.min(position + width - 1, #text))
    position = position + width
    return glyph
  end
end

return Utf8Glyphs
