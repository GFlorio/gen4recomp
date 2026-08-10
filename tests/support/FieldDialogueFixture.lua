-- Synthetic dialogue-renderer fixtures shared by the dialogue smoke suite and
-- the injected-failure suite: a 16x16 two-glyph font atlas, the cache holding
-- it, an opened controller with a canned layout, and the exact graphics-state
-- restoration contract a draw must honour.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")

local FieldDialogueFixture = {}

local DEF_PATH = "data/generated/field/font/font-0.lua"
local ATLAS_PATH = "assets/generated/field/font/font-0.png"

local function px(r, g, b, a)
  return string.char(r, g, b, a)
end

-- 16x16 atlas: two 8x16 glyph cells, red 'A' and green 'B'.
---@return string png
function FieldDialogueFixture.atlasBytes()
  local rgba = {}
  for _ = 1, 16 do
    for x = 1, 16 do
      rgba[#rgba + 1] = x <= 8 and px(200, 40, 40, 255) or px(40, 200, 40, 255)
    end
  end
  return PngWriter.encode(16, 16, table.concat(rgba))
end

---@return FieldFontDef
function FieldDialogueFixture.fontDef()
  return {
    schema = "g4-field-font-v1",
    fontId = 0,
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    atlas = { width = 16, height = 16, glyphsPerRow = 2, glyphWidth = 8, glyphHeight = 16 },
    glyphs = {
      [1] = { x = 0, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [2] = { x = 8, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [0] = { x = 0, y = 0, w = 8, h = 16, advance = 4, bearingX = 0, bearingY = 0 },
    },
    charmap = { A = 1, B = 2, [" "] = 0 },
  }
end

---@return string lua
function FieldDialogueFixture.encodedFontDef()
  return LuaWriter.encode(FieldDialogueFixture.fontDef())
end

---@return CacheFs
function FieldDialogueFixture.cacheWithFont()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write(DEF_PATH, FieldDialogueFixture.encodedFontDef())
  cache:write(ATLAS_PATH, FieldDialogueFixture.atlasBytes())
  return cache
end

-- An opened modal controller whose layout is canned, so the smoke tests
-- exercise the renderer rather than the layout engine.
---@param text string
---@return FieldDialogueController
function FieldDialogueFixture.openDialogue(text)
  local tokens = {
    { kind = "glyph", code = 1, text = "A", raw = { 1 } },
    { kind = "glyph", code = 2, text = "B", raw = { 2 } },
  }
  local controller = FieldDialogueController.new({
    layout = function()
      return {
        pages = { { lines = { { tokens = tokens, width = 12 } }, breakKind = "eos" } },
        warnings = {},
      }
    end,
  })
  controller:open({
    id = "smoke",
    message = { bankId = 543, messageId = 5, text = text, tokens = tokens, hadUnresolvedSubstitutions = false },
    style = "default",
    modal = true,
    allowCancel = false,
  })
  return controller
end

-- Every captured state (canvas, shader, blend, depth, wireframe, cull, color,
-- scissor) equals the pre-draw value, never a hard-coded default. The caller
-- sets exactly this state before drawing.
---@param lg table love.graphics-shaped namespace
function FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
  Assert.equal(lg.getCanvas(), canvas)
  Assert.equal(lg.getShader(), shader)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), true)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.near(r, 0.2, 1e-6)
  Assert.near(g, 0.4, 1e-6)
  Assert.near(b, 0.6, 1e-6)
  Assert.near(a, 0.8, 1e-6)
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 4)
  Assert.equal(sy, 8)
  Assert.equal(sw, 32)
  Assert.equal(sh, 16)
end

return FieldDialogueFixture
