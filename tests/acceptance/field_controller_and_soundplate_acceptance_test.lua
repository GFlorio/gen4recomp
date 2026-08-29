-- Production-composed field-audio contracts for controller and
-- soundplates. The runtime wires the real cache, the real player,
-- and the real GameSound; every scenario boots through the shared
-- acceptance harness and stops before any draw call.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "audio", "controller", "soundplate" },
  },
  tests = {},
}

local function day()
  return "day"
end

local function bootWithAudio(harness, versionId, map, fake)
  return harness:boot({
    versionId = versionId,
    map = map,
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      dayNight = day,
      audioOutput = fake,
    },
  })
end

local function requireAudio(game)
  Assert.isTrue(type(game.runtime.audio) == "table", "production audio must be wired at runtime.audio")
  return game.runtime.audio
end

function T.tests.production_audio_respects_authoritative_world_coordinates()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, "MAP_BURNED_TOWER_1F", fake)
    local ok, err = xpcall(function()
      local audio = requireAudio(game)
      local player = game.runtime.player
      Assert.isTrue(type(player.fieldX) == "number" and type(player.fieldZ) == "number")
      Assert.isTrue(rawget(player, "play") == nil, "FieldPlayer must not expose an audio play method")
      Assert.isTrue(type(audio.updateField) == "function")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.environment_selection_follows_the_replacement_player_after_warp()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, "MAP_BURNED_TOWER_1F", fake)
    local ok, err = xpcall(function()
      local audio = requireAudio(game)
      local beforePlayer = game.runtime.player
      local beforeFieldX = beforePlayer.fieldX
      local newPlayer = { fieldX = beforeFieldX + 1, fieldZ = beforePlayer.fieldZ }
      ---@cast newPlayer FieldPlayer
      game.runtime.player = newPlayer
      game.runtime.session.player = newPlayer
      Assert.notNil(audio.updateField, "controller must expose field-policy update")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.warp_to_different_field_music_starts_a_forty_frame_pre_fade()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, "MAP_BURNED_TOWER_1F", fake)
    local ok, err = xpcall(function()
      local audio = requireAudio(game)
      Assert.isTrue(audio:currentMusic() ~= nil, "lab must boot with map-header music")
      Assert.isFalse(audio:isMusicFadeActive(), "no fade must be active before the warp")
      audio:beginWarp("MAP_NEW_BARK")
      Assert.isTrue(audio:isMusicFadeActive(), "a different destination header must start the pre-fade")
      for _ = 1, 39 do
        game.runtime:update(1 / 60)
      end
      Assert.isTrue(audio:isMusicFadeActive(), "the forty-frame pre-fade must still be active before its final frame")
      game.runtime:update(1 / 60)
      Assert.isFalse(
        audio:isMusicFadeActive(),
        "the forty-frame pre-fade must complete after exactly forty sound frames"
      )
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

function T.tests.same_destination_music_skips_pre_fade_and_missing_field_data_raises()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, "MAP_BURNED_TOWER_1F", fake)
    local ok, err = xpcall(function()
      local audio = requireAudio(game)
      audio:beginWarp("MAP_BURNED_TOWER_1F")
      Assert.isFalse(audio:isMusicFadeActive(), "equal destination header must not start a pre-fade")
      Assert.throws(function()
        audio:beginWarp(999999)
      end)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
