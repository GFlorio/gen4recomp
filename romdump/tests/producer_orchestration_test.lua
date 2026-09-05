-- Producer ownership contracts for the cache stages and digest helpers.

local Assert = require("tests.support.Assert")

local T = {}

function T.new_domain_builders_are_concrete_modules()
  local modules = {
    "romdump.src.build.FieldCacheBuild",
    "romdump.src.build.ScriptAudioCacheBuild",
    "romdump.src.build.MapCacheBuild",
    "romdump.src.digest.model.DynamicModelCompiler",
    "romdump.src.digest.map.BuildingModelCompiler",
    "romdump.src.digest.newgame.IntroRasterizer",
  }
  for _, name in ipairs(modules) do
    local module = require(name)
    Assert.notNil(module, name .. " must load")
    Assert.isTrue(
      type(module.build or module.compile or module.render or module.renderChar) == "function",
      name .. " needs a focused seam"
    )
  end
end

return { tests = T }
