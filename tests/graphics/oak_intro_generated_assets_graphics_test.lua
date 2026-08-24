-- Generated-intro smoke: every real Marill idle frame must contain visible
-- chromatic pixels after loading through the LÖVE image-data boundary.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = {
    capabilities = { "graphics", "derived_cache" },
    tags = { "oak", "generated-assets" },
  },
  tests = {},
}

T.tests.every_generated_marill_idle_frame_is_visible_and_chromatic = function(context)
  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua("data/generated/intro/intro.lua"))
      local widget = assert(manifest.widgets.marill)
      for index, frame in ipairs(widget.frames) do
        local bytes = assert(cache:read(frame.image), "missing Marill frame " .. index)
        local data = love.image.newImageData(love.filesystem.newFileData(bytes, frame.image))
        local visible, chromatic = false, false
        for y = 0, data:getHeight() - 1 do
          for x = 0, data:getWidth() - 1 do
            local r, g, b, a = data:getPixel(x, y)
            if a > 0 then
              visible = true
              if math.max(r, g, b) - math.min(r, g, b) > 0 then
                chromatic = true
              end
            end
          end
        end
        data:release()
        Assert.isTrue(visible, versionId .. " Marill frame " .. index .. " is empty")
        Assert.isTrue(chromatic, versionId .. " Marill frame " .. index .. " is monochrome")
      end
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
  context = context -- capability is asserted by the runner
end

return T
