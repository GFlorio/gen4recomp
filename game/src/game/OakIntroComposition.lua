-- Production composition for the Oak/profile introduction. It validates and
-- reads generated assets, captures generated message templates, and transfers
-- audio and presentation ownership to the constructed Oak state.

local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local IntroAssetCache = require("libs.assets.src.IntroAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldFontLoader = require("libs.engine.src.FieldFontLoader")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local LocalClock = require("libs.engine.src.LocalClock")
local OakIntroController = require("libs.engine.src.OakIntroController")
local OakIntroState = require("game.src.game.OakIntroState")
local GameAudio = require("game.src.game.audio.GameAudio")

local OakIntroComposition = {}

local MESSAGE_IDS = {
  ["greeting.morning"] = 1,
  ["greeting.day"] = 2,
  ["greeting.evening"] = 3,
  ["greeting.night"] = 4,
  ["greeting.midnight"] = 5,
  ["oak.welcome"] = 6,
  ["oak.world_inhabited"] = 34,
  ["oak.live_alongside"] = 35,
  ["oak.tell_about_yourself"] = 36,
  ["profile.gender_question"] = 37,
  ["profile.gender_confirm.male"] = 38,
  ["profile.gender_confirm.female"] = 39,
  ["profile.name_prompt"] = 40,
  ["profile.name_confirm.male"] = 41,
  ["profile.name_confirm.female"] = 42,
  ["profile.final"] = 43,
}

local function mapMessages(getMessage)
  local messages = {}
  for key, messageId in pairs(MESSAGE_IDS) do
    local message = assert(getMessage(messageId))
    messages[key] = message
  end
  return messages
end

function OakIntroComposition.messageKeys(messages)
  return mapMessages(function(messageId)
    return messages[messageId]
  end)
end

function OakIntroComposition.randomU32(mathHost)
  mathHost = mathHost or love.math
  assert(type(mathHost.random) == "function", "Oak intro requires love.math.random")
  return function()
    local high = mathHost.random(0, 0xFFFF)
    local low = mathHost.random(0, 0xFFFF)
    return high * 0x10000 + low
  end
end

local function virtualGlyphs(charmap)
  local glyphs = {}
  for glyph in pairs(charmap) do
    if type(glyph) == "string" and glyph ~= "" then
      glyphs[#glyphs + 1] = glyph
    end
  end
  table.sort(glyphs)
  assert(#glyphs > 0, "generated field font charmap has no virtual keyboard glyphs")
  return glyphs
end

local function generatedImageLoader(cacheFs, graphics)
  return function(path)
    local bytes = assert(cacheFs:read(path), "missing generated Oak image " .. path)
    local fileData = love.filesystem.newFileData(bytes, path)
    return graphics.newImage(fileData, { linear = false, mipmaps = false })
  end
end

local function validManifest(manifest, validate, name)
  local valid, err = validate(manifest)
  if not valid then
    error(err or (name .. " manifest is invalid"), 0)
  end
  return manifest
end

---@param options table
---@return OakIntroState
function OakIntroComposition.compose(options)
  assert(type(options) == "table", "Oak intro composition requires options")
  assert(type(options.candidate) == "table", "Oak intro composition requires a candidate")
  assert(type(options.versionId) == "string", "Oak intro composition requires a version")

  local cacheFs = CacheFs.forVersion(options.versionId)
  local introManifest =
    validManifest(assert(cacheFs:loadLua(IntroAssetCache.manifestPath())), IntroAssetCache.validateManifest, "intro")
  local uiManifest = validManifest(
    assert(cacheFs:loadLua(FieldUiAssetCache.manifestPath())),
    FieldUiAssetCache.validateManifest,
    "field UI"
  )
  local fontDef = FieldFontLoader.load(cacheFs)
  local frameIndexes = {}
  for frame = 0, uiManifest.dialogueFrames.count - 1 do
    frameIndexes[frame] = true
  end
  local playerDataContext = { charmap = fontDef.charmap, frameIndexes = frameIndexes }

  local provider = FieldMessageProvider.new(cacheFs)
  local bankAcquired = false
  local audio
  local audioLifetime
  local ok, state = pcall(function()
    assert(provider:acquireBank(219))
    bankAcquired = true
    local messages = mapMessages(function(messageId)
      return provider:get(219, messageId)
    end)
    provider:releaseBank(219)
    bankAcquired = false

    audio = GameAudio.compose({
      cacheFs = cacheFs,
      outputRate = 32768,
      outputHost = options.audioOutput,
    })
    audioLifetime = {
      dispose = function(self)
        if self.disposed then
          return
        end
        self.disposed = true
        if audio.sink then
          audio.sink:release()
        end
      end,
    }

    local graphics = options.graphics or love.graphics
    local controller = OakIntroController.new({
      candidate = options.candidate,
      clock = options.clock or LocalClock.system(),
      audio = audio.sound,
      messages = messages,
      assets = introManifest.assets,
      playerDataContext = playerDataContext,
      randomU32 = options.randomU32 or OakIntroComposition.randomU32(),
      virtualGlyphs = virtualGlyphs(fontDef.charmap),
    })
    return OakIntroState.new({
      controller = controller --[[@as any]],
      manifest = introManifest,
      graphics = graphics,
      imageLoader = options.imageLoader or generatedImageLoader(cacheFs, graphics),
      textInputHost = options.textInputHost,
      width = options.width,
      height = options.height,
      onComplete = options.onComplete,
      audioSink = audio.sink --[[@as OakIntroStateAudioSink?]],
      audioLifetime = audioLifetime,
    })
  end)
  if not ok then
    if bankAcquired then
      pcall(provider.releaseBank, provider, 219)
    end
    if audioLifetime then
      audioLifetime:dispose()
    elseif audio and audio.sink then
      audio.sink:release()
    end
    error(state, 0)
  end
  return state
end

return OakIntroComposition
