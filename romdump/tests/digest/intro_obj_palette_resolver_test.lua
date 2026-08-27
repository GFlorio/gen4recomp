-- Unit coverage for palette-slot namespace resolution used before intro OBJ
-- rasterization: explicit selector zero, out-of-range/ambiguous slots fail
-- descriptively instead of falling back to a color, and 8bpp resources never
-- run 4bpp slot arithmetic.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local IntroObjPaletteResolver = require("romdump.src.digest.IntroObjPaletteResolver")

local T = {}

local function colorTable(count)
  local colors = {}
  for index = 1, count do
    colors[index] = { r = index, g = index, b = index }
  end
  return colors
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

function T.selector_zero_resolves_the_first_slot_explicitly()
  local colors = colorTable(32)
  local view, slot = IntroObjPaletteResolver.resolve(colors, 3, 0)
  Assert.equal(slot, 0)
  Assert.equal(#view, 16)
  Assert.equal(view[1], colors[1])
  Assert.equal(view[16], colors[16])
end

function T.selector_selects_a_later_slot_within_the_loaded_resource()
  local colors = colorTable(80)
  local view, slot = IntroObjPaletteResolver.resolve(colors, 3, 4)
  Assert.equal(slot, 4)
  Assert.equal(view[1], colors[65])
  Assert.equal(view[16], colors[80])
end

function T.out_of_range_slot_fails_instead_of_falling_back()
  local colors = colorTable(32)
  throwsCode(IntroObjPaletteResolver.ERROR.INVALID_SLOT, function()
    IntroObjPaletteResolver.resolve(colors, 3, 4)
  end)
end

function T.ambiguous_palette_resource_size_fails_before_slicing()
  local colors = colorTable(20)
  throwsCode(IntroObjPaletteResolver.ERROR.INVALID_SLOT, function()
    IntroObjPaletteResolver.resolve(colors, 3, 0)
  end)
end

function T.missing_selector_fails_for_4bpp_resources()
  local colors = colorTable(16)
  throwsCode(IntroObjPaletteResolver.ERROR.INVALID_SLOT, function()
    IntroObjPaletteResolver.resolve(colors, 3, nil)
  end)
end

function T.eightbpp_resources_never_apply_fourbpp_slot_arithmetic()
  local colors = colorTable(256)
  local view, slot = IntroObjPaletteResolver.resolve(colors, 4, nil)
  Assert.equal(slot, 0)
  Assert.equal(#view, 256)
  Assert.equal(view, colors)
end

function T.eightbpp_resources_reject_an_explicit_selector()
  local colors = colorTable(256)
  throwsCode(IntroObjPaletteResolver.ERROR.INVALID_SLOT, function()
    IntroObjPaletteResolver.resolve(colors, 4, 0)
  end)
end

return { tests = T }
