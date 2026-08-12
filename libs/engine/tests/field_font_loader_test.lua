-- Field font definitions are runtime data. Loading them must not allocate a
-- presentation resource, so field composition can lay out dialogue before a
-- renderer exists.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")

local T = {}

function T.loads_the_compiled_definition_without_a_graphics_namespace()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local definition = { schema = FieldFontCache.SCHEMA, charmap = {}, glyphs = {} }
  cache:writeLua(FieldFontCache.defPath(0), definition)
  Assert.deepEqual(FieldFontLoader.load(cache), definition)
end

return T
