-- Resolves an Oak-speech OBJ sprite's palette slot into the exact indexed
-- colors used for rasterization. HGSS's OakSpeech/SpriteSystem code
-- (src/oaks_speech_obj.c, sSpriteTemplates) assigns each sprite template a
-- `.pal` value consumed by Sprite_SetPaletteOverride, but that numeral names
-- a slot in the sprite system's shared VRAM palette manager, not a bank
-- inside this resource's own decoded NCLR: real ROM data shows resource sets
-- shared by multiple sprites (e.g. the ball/Marill resource set) hold more
-- than one genuinely populated 16-color bank, correctly split across objects
-- by their own decoded OAM palette field, while the `.pal` numeral is a
-- provenance fact about the pinned source template rather than a usable
-- local index. Callers therefore call `resolve` twice: once to validate the
-- declared template selector against this resource for provenance, and once
-- per OAM object with that object's own decoded palette field to get the
-- exact colors used to rasterize it.

local Errors = require("libs.errors.src.Errors")

local IntroObjPaletteResolver = {}

IntroObjPaletteResolver.ERROR = { INVALID_SLOT = "INTRO_OBJ_PALETTE_SLOT_INVALID" }

local function invalidSlot(message, context)
  Errors.raise(IntroObjPaletteResolver.ERROR.INVALID_SLOT, message, context or {})
end

--- Resolve `selector` against the palette resource `colors` decoded for one
--- intro sprite's resource set.
---@param colors table[] flat decoded palette colors for the sprite's loaded palette resource
---@param depth number char bit depth: 3 selects 4bpp (16-color slots), 4 selects 8bpp (one 256-color table)
---@param selector number|nil source template/override palette slot; required for 4bpp, must be absent for 8bpp
---@return table[] view exact colors used for pixel-index lookup (16 entries for 4bpp, the full table for 8bpp)
---@return number resolvedSlot the slot actually selected (always 0 for 8bpp)
function IntroObjPaletteResolver.resolve(colors, depth, selector)
  assert(type(colors) == "table", "intro palette resolver requires decoded palette colors")
  assert(depth == 3 or depth == 4, "unsupported intro char bit depth: " .. tostring(depth))
  if depth == 4 then
    if selector ~= nil then
      invalidSlot("intro palette override is invalid for 8bpp cell graphics", { selector = selector })
    end
    return colors, 0
  end
  if selector == nil then
    invalidSlot("intro 4bpp cell graphics require an explicit source palette selector", {})
  end
  if type(selector) ~= "number" or selector % 1 ~= 0 or selector < 0 then
    invalidSlot("intro palette selector is invalid", { selector = selector })
  end
  if #colors % 16 ~= 0 then
    invalidSlot("intro palette resource cannot be divided into 16-color slots unambiguously", {
      selector = selector,
      colorCount = #colors,
    })
  end
  local bankStart = selector * 16
  if bankStart + 16 > #colors then
    invalidSlot("intro palette selector is outside the loaded palette resource", {
      selector = selector,
      available = #colors,
    })
  end
  local view = {}
  for index = 1, 16 do
    view[index] = colors[bankStart + index]
  end
  ---@cast selector number
  return view, selector
end

return IntroObjPaletteResolver
