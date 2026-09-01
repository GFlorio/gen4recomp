-- Unit coverage for the absolute MAIN/SUB OBJ palette-bank ownership used by
-- the HGSS Oak source templates. The source transfer order is significant;
-- these records deliberately have nonmonotonic object ids.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local IntroObjPaletteResolver = require("romdump.src.digest.IntroObjPaletteResolver")

local T = {}

local function record(objectId, vram, bankCount)
  return {
    objectId = objectId,
    narcId = 120,
    fileId = objectId + 100,
    compressed = 0,
    vram = vram,
    bankCount = bankCount,
  }
end

local function structuredError(fn, label)
  local err = Assert.throws(fn, label)
  Assert.isTrue(Errors.is(err), label .. " must raise a structured error")
  return err
end

function T.source_order_allocates_main_and_sub_banks_independently()
  local layout = IntroObjPaletteResolver.build({
    record(90, 1, 2),
    record(12, 2, 1),
    record(7, 3, 1),
    record(2, 1, 1),
    record(99, 2, 2),
  })

  local owner, localBank = IntroObjPaletteResolver.owner(layout, "main", 0)
  Assert.equal(owner.objectId, 90)
  Assert.equal(localBank, 0)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "main", 1)
  Assert.equal(owner.objectId, 90)
  Assert.equal(localBank, 1)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "main", 2)
  Assert.equal(owner.objectId, 7)
  Assert.equal(localBank, 0)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "main", 3)
  Assert.equal(owner.objectId, 2)
  Assert.equal(localBank, 0)

  owner, localBank = IntroObjPaletteResolver.owner(layout, "sub", 0)
  Assert.equal(owner.objectId, 12)
  Assert.equal(localBank, 0)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "sub", 1)
  Assert.equal(owner.objectId, 7)
  Assert.equal(localBank, 0)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "sub", 2)
  Assert.equal(owner.objectId, 99)
  Assert.equal(localBank, 0)
  owner, localBank = IntroObjPaletteResolver.owner(layout, "sub", 3)
  Assert.equal(owner.objectId, 99)
  Assert.equal(localBank, 1)
end

function T.invalid_layout_records_fail_without_fallback()
  for _, invalid in ipairs({
    record(1, 1, 0),
    record(2, 1, -1),
    record(3, 1, 1.5),
    record(4, 0, 1),
    record(5, 4, 1),
    record(6, 1, 1),
  }) do
    if invalid.objectId == 6 then
      invalid.objectId = nil
    end
    structuredError(function()
      IntroObjPaletteResolver.build({ invalid })
    end, "malformed palette layout record")
  end

  local duplicate = record(8, 1, 1)
  structuredError(function()
    IntroObjPaletteResolver.build({ record(8, 2, 1), duplicate })
  end, "duplicate palette resource id")
end

function T.owner_rejects_unknown_engine_invalid_slot_and_missing_owner()
  local layout = IntroObjPaletteResolver.build({ record(4, 1, 1) })
  for _, engine in ipairs({ "sideways", "MAIN" }) do
    structuredError(function()
      IntroObjPaletteResolver.owner(layout, engine --[[@as "main"|"sub"]], 0)
    end, "unknown palette engine")
  end
  for _, slot in ipairs({ -1, 0.5 }) do
    structuredError(function()
      IntroObjPaletteResolver.owner(layout, "main", slot)
    end, "invalid absolute palette slot")
  end
  structuredError(function()
    IntroObjPaletteResolver.owner(layout, "sub", 0)
  end, "missing absolute palette owner")
  structuredError(function()
    IntroObjPaletteResolver.owner(layout, "main", 1)
  end, "out-of-range absolute palette owner")
end

function T.slice_selects_one_exact_local_fourbpp_bank()
  local colors = {}
  for index = 1, 48 do
    colors[index] = { r = index, g = index + 1, b = index + 2 }
  end
  local view = IntroObjPaletteResolver.slice(colors, 3, 2)
  Assert.equal(#view, 16)
  Assert.equal(view[1], colors[33])
  Assert.equal(view[16], colors[48])
end

function T.slice_rejects_short_non_fourbpp_and_invalid_local_banks()
  local colors = {}
  for index = 1, 32 do
    colors[index] = { r = index, g = index, b = index }
  end
  for _, args in ipairs({
    { colors, 3, 2 },
    { colors, 4, 0 },
    { colors, 3, -1 },
    { colors, 3, 0.5 },
  }) do
    structuredError(function()
      IntroObjPaletteResolver.slice(args[1], args[2], args[3])
    end, "invalid local palette bank")
  end
end

return { tests = T }
