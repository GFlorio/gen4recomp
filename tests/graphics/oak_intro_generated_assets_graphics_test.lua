-- Generated-intro smoke: every frame of the critical Oak-speech widgets
-- (female, ball, Marill reveal, Marill idle) must contain visible chromatic
-- pixels after loading through the LÖVE image-data boundary, independent of
-- OakIntroRenderer.

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

local CRITICAL_WIDGETS = { "female", "ball_open", "marill_appear", "marill" }

local function assertVisibleChromatic(cache, versionId, widgetId, widget)
  for index, frame in ipairs(widget.frames) do
    local bytes = assert(cache:read(frame.image), "missing " .. widgetId .. " frame " .. index)
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
    Assert.isTrue(visible, versionId .. " " .. widgetId .. " frame " .. index .. " is empty")
    Assert.isTrue(chromatic, versionId .. " " .. widgetId .. " frame " .. index .. " is monochrome")
  end
end

T.tests.every_critical_intro_widget_frame_is_visible_and_chromatic = function(context)
  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua("data/generated/intro/intro.lua"))
      for _, widgetId in ipairs(CRITICAL_WIDGETS) do
        local widget = assert(manifest.widgets[widgetId], versionId .. " missing widget " .. widgetId)
        assertVisibleChromatic(cache, versionId, widgetId, widget)
      end
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
  context = context -- capability is asserted by the runner
end

T.tests.gender_portrait_frames_have_source_pixels_and_centers = function()
  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua("data/generated/intro/intro.lua"))
      local centers = {
        gender_male = { x = 64, y = 104 },
        gender_female = { x = 192, y = 104 },
      }
      for widgetId, center in pairs(centers) do
        local widget = assert(manifest.widgets[widgetId], versionId .. " missing widget " .. widgetId)
        Assert.deepEqual(widget.sourceCenter, center, versionId .. " " .. widgetId .. " source center")
        assertVisibleChromatic(cache, versionId, widgetId, widget)
      end
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
end

T.tests.gender_card_backings_are_opaque = function()
  local ready = 0
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      ready = ready + 1
      local cache = CacheFs.forVersion(versionId)
      local manifest = assert(cache:loadLua("data/generated/intro/intro.lua"))
      local selector = assert(manifest.genderSelector)
      for _, gender in ipairs({ "male", "female" }) do
        local backing = assert(selector.buttons[gender].backing)
        local bytes = assert(cache:read(backing.image), versionId .. " " .. gender .. " backing is missing")
        local data = love.image.newImageData(love.filesystem.newFileData(bytes, backing.image))
        for _, point in ipairs({ { 0, 0 }, { backing.width - 1, backing.height - 1 } }) do
          local _, _, _, alpha = data:getPixel(point[1], point[2])
          Assert.equal(alpha, 1, versionId .. " " .. gender .. " backing corner is opaque")
        end
        data:release()
      end
    end
  end
  Assert.isTrue(ready > 0, "derived-cache capability promised a ready game version")
end

return T
