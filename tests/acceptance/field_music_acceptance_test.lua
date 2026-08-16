-- Production-composed field-audio contracts. The scenarios boot the real
-- FieldRuntime with the production audio composition (the runtime wires
-- AudioAssetProvider/SequencePlayer/VoiceMixer/GameSound and the LÖVE sink
-- over the injected audio-output host boundary) and drive the field
-- integration order: boot map-header music, day/night selection, scripted
-- PlaySE over BGM, the WaitSE wait state, fanfare suspend/restore, blocking
-- fades, StopBGM, ResetBGM, and the map-swap policy handoff. The map-music
-- policy is a plain day/night lookup over the generated field record's
-- canonical audio references (the composition never decorates symbols).
-- Audio output is the faked host boundary (FakeAudioOutput); the
-- composition, the engine playback state, and the real script platform stay
-- production.

local Assert = require("tests.support.Assert")
local AudioCache = require("libs.assets.src.AudioCache")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "audio", "music" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local NEW_BARK_MUSIC = "SEQ_GS_T_WAKABA"
local LAB_MUSIC = "SEQ_GS_UTSUGI_RABO"

local function day()
  return "day"
end

local function night()
  return "night"
end

-- Boot the production runtime with the real audio composition: no recording
-- audio adapter (the runtime wires GameSound at scriptHosts.audio), a
-- deterministic day/night source, and the fake audio-output host boundary.
local function bootWithAudio(harness, versionId, map, dayNight, fake)
  return harness:boot({
    versionId = versionId,
    map = map,
    save = "fresh",
    fieldOptions = {
      audioHost = "production",
      dayNight = dayNight,
      audioOutput = fake,
    },
  })
end

local function requireAudio(game)
  Assert.isTrue(
    type(game.runtime.audio) == "table",
    "production composition must wire the real GameSound at runtime.audio"
  )
  return game.runtime.audio
end

-- The resolved id of a sequence symbol in the generated audio index the
-- runtime loaded through production composition.
local function musicId(game, symbol)
  local index = assert(
    game.runtime.cacheFs:loadLua(AudioCache.indexPath()),
    "the generated audio index must load through the runtime cache"
  )
  local id = index.sequenceBySymbol[symbol]
  assert(id ~= nil, symbol .. " must resolve in the generated audio index")
  return id
end

-- Drive a scripted interaction through the production scheduler and dialogue
-- flow, closing the game after the assertions; render attempts are fatal.
local function withProductionAudio(map, dayNight, fn)
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, map, dayNight, fake)
    local ok, err = xpcall(function()
      fn(game, fake)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

-- Booting a field map starts its map-header music, which the day/night
-- selection resolves from the generated field-map record. The record carries
-- canonical audio sequence references (never bare suffixes the runtime must
-- decorate); all real maps carry equal day/night music in the frozen catalog,
-- so the selection is observed through the record's day/night branches and
-- the booted reference, and the day/night lookup itself is a plain table read
-- over the generated record.
function T.tests.boot_starts_the_generated_maps_header_music_for_day_and_night()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local dayFake = FakeAudioOutput.new()
    local dayGame = bootWithAudio(harness, versionId, TOWN, day, dayFake)
    local ok, err = xpcall(function()
      local audio = requireAudio(dayGame)
      local map = dayGame.runtime.runtimeMap
      -- The generated field record carries the frozen catalog's day and
      -- night music as canonical audio references through the production
      -- map load.
      Assert.deepEqual(map.fieldData.music, { day = NEW_BARK_MUSIC, night = NEW_BARK_MUSIC })
      Assert.equal(map.fieldData.music[day()], NEW_BARK_MUSIC)
      -- The boot started the map-header music through the composition.
      Assert.equal(audio:currentMusic(), musicId(dayGame, NEW_BARK_MUSIC))
      -- The audio-output host actually receives the music.
      dayGame:advanceUntil("map music renders into the audio-output host", function()
        return dayFake:anyNonSilent()
      end, 120)
      Assert.equal(dayGame:renderAttempts(), 0)
    end, debug.traceback)
    dayGame:close()
    if not ok then
      error(err, 0)
    end

    local nightFake = FakeAudioOutput.new()
    local nightGame = bootWithAudio(harness, versionId, TOWN, night, nightFake)
    local ok2, err2 = xpcall(function()
      local audio = requireAudio(nightGame)
      -- The night branch reads the generated record's nightMusic.
      Assert.equal(nightGame.runtime.runtimeMap.fieldData.music[night()], NEW_BARK_MUSIC)
      Assert.equal(audio:currentMusic(), musicId(nightGame, NEW_BARK_MUSIC))
      Assert.equal(nightGame:renderAttempts(), 0)
    end, debug.traceback)
    nightGame:close()
    if not ok2 then
      error(err2, 0)
    end

    -- A second map boots a different map-header music: the selection is
    -- data-driven by the generated record, never a map-id switch.
    local labFake = FakeAudioOutput.new()
    local labGame = bootWithAudio(harness, versionId, LAB, day, labFake)
    local ok3, err3 = xpcall(function()
      local audio = requireAudio(labGame)
      Assert.equal(labGame.runtime.runtimeMap.fieldData.music[day()], LAB_MUSIC)
      Assert.equal(audio:currentMusic(), musicId(labGame, LAB_MUSIC))
      labGame:advanceUntil("the lab music renders into the audio-output host", function()
        return labFake:anyNonSilent()
      end, 120)
    end, debug.traceback)
    labGame:close()
    if not ok3 then
      error(err3, 0)
    end
  end)
end

-- The New Bark woman's real vanilla script plays SEQ_SE_DP_SELECT through
-- the production scheduler and the real GameSound; the effect overlaps the
-- map BGM (distinct players), ends on its own, and leaves the BGM running.
function T.tests.a_scripted_play_sound_overlaps_the_map_bgm()
  withProductionAudio(TOWN, day, function(game, fake)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    game:moveTo({ fieldX = 683, fieldZ = 400 })
    game:face("north")
    game:pressAction()
    Assert.isTrue(audio:isEffectPlaying("SEQ_SE_DP_SELECT"), "the scripted SE must be playing")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the map BGM must keep playing under the SE")
    Assert.equal(audio:currentMusic(), wakaba, "the BGM reference must survive the scripted SE")

    game:advanceDialogue()
    game:advanceUntil("interaction releases field control", function(snapshot)
      return not snapshot.dialogue.modal and not snapshot.fieldLocked
    end, 480)
    game:advanceUntil("the scripted SE completes on its own", function()
      return not audio:isEffectPlaying("SEQ_SE_DP_SELECT")
    end, 240)
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the BGM must continue after the SE ends")
    Assert.equal(audio:currentMusic(), wakaba)
    game:advanceUntil("the BGM stays audible after the SE", function()
      return fake:anyNonSilent()
    end, 60)
  end)
end

-- An effect started through the production service stays playing until
-- the engine player finishes it (the poll the WaitSE task blocks on) while
-- the map BGM continues underneath.
function T.tests.wait_sound_state_blocks_until_the_effect_ends_and_the_bgm_continues()
  withProductionAudio(TOWN, day, function(game)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    audio:play("SEQ_SE_DP_KAIDAN2")
    Assert.isTrue(audio:isEffectPlaying("SEQ_SE_DP_KAIDAN2"), "the WaitSE poll must see the effect playing")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the BGM must continue under the effect")
    game:advanceUntil("the effect finishes and the wait resumes", function()
      return not audio:isEffectPlaying("SEQ_SE_DP_KAIDAN2")
    end, 240)
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the BGM must outlive the effect")
    Assert.equal(audio:currentMusic(), wakaba)
  end)
end

-- A fanfare PAUSES the map BGM player (the HGSS PlayFanfare
-- NNS_SndPlayerPause transport pause: the sequence stays held and resumes at
-- its preserved position) while keeping its reference; after the playback +
-- post-wait interval the same reference is restored and renders again.
function T.tests.a_fanfare_suspends_the_map_bgm_and_restores_it()
  withProductionAudio(TOWN, day, function(game, fake)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    audio:playFanfare("SEQ_ME_ITEM")
    Assert.isTrue(audio:isFanfarePlaying(), "the fanfare must be playing")
    Assert.equal(audio:currentMusic(), wakaba, "the fanfare must keep the suspended BGM reference")
    Assert.isTrue(
      audio:isEffectPlaying(NEW_BARK_MUSIC),
      "the BGM player is paused, not stopped, while the fanfare plays"
    )

    game:advanceUntil("the fanfare ends, the post-wait passes, and the BGM resumes", function()
      return not audio:isFanfarePlaying() and audio:isEffectPlaying(NEW_BARK_MUSIC)
    end, 900)
    Assert.equal(audio:currentMusic(), wakaba, "the restored BGM is the suspended map music")
    game:advanceUntil("the restored BGM renders into the audio-output host", function()
      return fake:anyNonSilent()
    end, 60)
  end)
end

-- A fade-out blocks (the isMusicFadeActive poll the MusicFadeTask
-- waits on) for exactly its requested field ticks; a fade never stops the
-- BGM player (a fade-out to 0 leaves it running silent at the target level),
-- and the matching fade-in ramps the same player back to full without
-- replaying it.
function T.tests.music_fades_block_for_their_requested_durations()
  withProductionAudio(TOWN, day, function(game)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    audio:fadeMusicOut({ target = 0, durationTicks = 30 })
    Assert.isTrue(audio:isMusicFadeActive(), "the fade must be active in its start tick")
    for _ = 1, 29 do
      game:step()
    end
    Assert.isTrue(audio:isMusicFadeActive(), "the fade must still block before its requested duration")
    game:step()
    Assert.isFalse(audio:isMusicFadeActive(), "the fade must complete at exactly its requested duration")
    Assert.equal(audio:currentMusic(), wakaba, "the fade-out to 0 must keep the reference for a later fade-in")
    Assert.isTrue(
      audio:isEffectPlaying(NEW_BARK_MUSIC),
      "a fade never stops the BGM player; it keeps playing at the target level"
    )

    audio:fadeMusicIn({ durationTicks = 20 })
    Assert.isTrue(audio:isMusicFadeActive(), "the fade-in must be active in its start tick")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the fade-in never replays the BGM; the player kept running")
    for _ = 1, 19 do
      game:step()
    end
    Assert.isTrue(audio:isMusicFadeActive(), "the fade-in must still block before its requested duration")
    game:step()
    Assert.isFalse(audio:isMusicFadeActive(), "the fade-in must complete at exactly its requested duration")
    Assert.equal(audio:currentMusic(), wakaba)
  end)
end

-- StopBGM stops the current music (its source operand is an erasure at
-- lowering and at the service), and ResetBGM plays the current map-header
-- day/night music -- never the previously played reference.
function T.tests.stop_bgm_then_reset_bgm_follows_the_map_header_music()
  withProductionAudio(TOWN, day, function(game, fake)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    audio:playMusic("SEQ_GS_UTSUGI_RABO")
    Assert.equal(audio:currentMusic(), musicId(game, "SEQ_GS_UTSUGI_RABO"))
    game:advanceUntil("the replacement BGM renders", function()
      return fake:anyNonSilent()
    end, 60)

    audio:stopMusic()
    Assert.isNil(audio:currentMusic(), "StopBGM must stop the current music")
    Assert.isFalse(audio:isEffectPlaying("SEQ_GS_UTSUGI_RABO"), "StopBGM must stop the current BGM player")
    game:advanceUntil("the stopped music falls silent in the audio-output host", function()
      return fake:silentChunksSinceLastNonSilent() >= 2
    end, 60)

    audio:resetMusic()
    Assert.equal(audio:currentMusic(), wakaba, "ResetBGM must play the map-header music, not the previous BGM")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC))
    game:advanceUntil("the reset map music renders", function()
      return fake:anyNonSilent()
    end, 60)
  end)
end

-- A real lab-to-town warp updates the field-music policy to the
-- destination map and the composition starts the destination's music; the
-- old map BGM is not left playing, and a later reset keeps the new policy.
function T.tests.map_swap_updates_the_field_music_policy_without_orphaning_the_old_bgm()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    local game = bootWithAudio(harness, versionId, LAB, day, fake)
    local ok, err = xpcall(function()
      local audio = requireAudio(game)
      local labMusic = musicId(game, LAB_MUSIC)
      local wakaba = musicId(game, NEW_BARK_MUSIC)
      Assert.equal(audio:currentMusic(), labMusic, "the lab boots its own map-header music")
      Assert.isTrue(audio:isEffectPlaying(LAB_MUSIC))

      game:moveTo({ fieldX = 4, fieldZ = 14 })
      game:face("south")
      local transition = game:waitForTransition()
      Assert.equal(transition.destination.mapSymbol, TOWN)
      Assert.equal(game:snapshot().mapSymbol, TOWN)

      -- The policy follows the destination map (the generated record's
      -- canonical day reference) and the composition starts its music; the
      -- old map BGM is replaced, not left playing.
      Assert.equal(game.runtime.runtimeMap.fieldData.music[day()], NEW_BARK_MUSIC)
      Assert.equal(audio:currentMusic(), wakaba, "the composition must start the destination map's music")
      Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC))
      game:advanceUntil("the destination music renders after the warp", function()
        return fake:anyNonSilent()
      end, 120)

      -- A reset after the swap keeps the destination policy (no stale source
      -- map reference).
      audio:resetMusic()
      Assert.equal(audio:currentMusic(), wakaba, "reset after a warp must keep the destination map music")
      Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC))
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
