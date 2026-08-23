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
-- production. The script audio service and the production output
-- composition are independent axes: one scenario pins that a recording
-- script adapter can coexist with the production composition when an
-- audio-output host is explicitly requested.

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

local function requireAudio(game, message)
  Assert.isTrue(
    type(game.runtime.audio) == "table",
    message or "production composition must wire the real GameSound at runtime.audio"
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
      -- map load, plus the compiled music policy: New Bark has no
      -- flag-driven overrides, and the surfing traversal rule is the
      -- source's SEQ_GS_NAMINORI unless the suppressing flag is set.
      Assert.deepEqual(map.fieldData.music, {
        day = NEW_BARK_MUSIC,
        night = NEW_BARK_MUSIC,
        flagOverrides = {},
        traversalOverrides = {
          { traversal = "surfing", sequence = "SEQ_GS_NAMINORI", unlessFlagId = 0x99A },
        },
      })
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

-- The map-header composition must remain alive through a sustained production
-- window after its accompaniment has had time to open and execute. This is
-- intentionally driven by semantic runtime steps rather than a fixed short
-- render probe: a late reservation/lifecycle regression can pass the first
-- audible chunk while losing the map music afterward.
function T.tests.new_bark_music_survives_a_sustained_production_window()
  withProductionAudio(TOWN, day, function(game, fake)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    Assert.equal(audio:currentMusic(), wakaba, "New Bark must start its map-header music")

    game:advanceUntil("New Bark music becomes audible", function()
      return fake:anyNonSilent()
    end, 120)

    for _ = 1, 600 do
      game:step()
    end

    Assert.equal(audio:currentMusic(), wakaba, "the sustained New Bark run must retain its music identity")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the sustained New Bark run must retain active music")
    Assert.isTrue(fake:anyNonSilent(), "the sustained New Bark run must remain audible")
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
-- waits on) for exactly its requested sound frames at the 60 Hz wall-clock
-- cadence; a fade never stops the BGM player (a fade-out to 0 leaves it
-- running silent at the target level), and the matching fade-in ramps the
-- same player back to full without replaying it. The durations are sound
-- frames, so the test drives the runtime's 60 Hz accumulator directly with
-- 1/60 updates -- one host update per semantic frame, not one field tick
-- (a field tick is 1/30 and would advance two frames).
function T.tests.music_fades_block_for_their_requested_durations()
  withProductionAudio(TOWN, day, function(game)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    audio:fadeMusicOut({ target = 0, durationTicks = 30 })
    Assert.isTrue(audio:isMusicFadeActive(), "the fade must be active in its start tick")
    for _ = 1, 29 do
      game.runtime:update(1 / 60)
    end
    Assert.isTrue(audio:isMusicFadeActive(), "the fade must still block before its requested duration")
    game.runtime:update(1 / 60)
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
      game.runtime:update(1 / 60)
    end
    Assert.isTrue(audio:isMusicFadeActive(), "the fade-in must still block before its requested duration")
    game.runtime:update(1 / 60)
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

-- The retail field corpus reaches cries and temporary music (census:
-- play_cry/wait_cry and temporary_music all occur in reachable scripts), so
-- the production composition must execute them: a reachable audio operation
-- may never fail only when executed.
function T.tests.cries_and_temporary_music_execute_through_the_production_composition()
  withProductionAudio(TOWN, day, function(game, fake)
    local audio = requireAudio(game)
    audio:playCry(25, 0)
    Assert.isFalse(audio:isCryFinished(), "a reachable cry must start through the production composition")
    game:advanceUntil("the cry completes", function()
      return audio:isCryFinished()
    end, 900)
    audio:temporaryMusic("SEQ_GS_EYE_J_SHOUJO")
    Assert.isTrue(
      audio:isEffectPlaying("SEQ_GS_EYE_J_SHOUJO"),
      "temporary music must start its sequence through the production composition"
    )
    game:advanceUntil("temporary music renders into the audio-output host", function()
      return fake:anyNonSilent()
    end, 60)
  end)
end

-- The script audio service and the production composition are independent
-- composition axes: injecting a recording script adapter must not implicitly
-- suppress the production renderer/output composition when an audio-output
-- host is explicitly requested. The recording adapter stays the script
-- service (scripted audio lands there), while the production composition
-- boots the map-header music and pumps it into the host.
function T.tests.recording_script_audio_and_production_output_are_separate_composition_axes()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local fake = FakeAudioOutput.new()
    -- A recording script audio adapter (the harness default; no
    -- `audioHost = "production"`) together with an explicit audio-output
    -- host: neither axis may force the other.
    local game = harness:boot({
      versionId = versionId,
      map = TOWN,
      save = "fresh",
      fieldOptions = {
        dayNight = day,
        audioOutput = fake,
        recordingScriptHosts = true,
      },
    })
    local ok, err = xpcall(function()
      local audio = requireAudio(
        game,
        "an audio-output host must construct the production composition even with a recording script service"
      )
      -- The boot starts the map-header music through the production
      -- composition and the sink renders it into the host.
      Assert.equal(audio:currentMusic(), musicId(game, NEW_BARK_MUSIC))
      game:advanceUntil("map music renders into the audio-output host", function()
        return fake:anyNonSilent()
      end, 120)

      -- Scripts still receive the recording adapter: the New Bark woman's
      -- scripted SE is recorded there, never on the production service.
      game:moveTo({ fieldX = 683, fieldZ = 400 })
      game:face("north")
      game:pressAction()
      local effects = game:hostEffects()
      local recorded = false
      for _, entry in ipairs(effects) do
        if entry == "audio:SEQ_SE_DP_SELECT" then
          recorded = true
          break
        end
      end
      Assert.isTrue(recorded, "the scripted SE must reach the recording script adapter")
      Assert.isFalse(
        audio:isEffectPlaying("SEQ_SE_DP_SELECT"),
        "the production service must not receive the scripted SE"
      )
      Assert.equal(audio:currentMusic(), musicId(game, NEW_BARK_MUSIC), "the BGM must be unaffected by the scripted SE")
      game:advanceDialogue()
      game:advanceUntil("the map music keeps rendering under the scripted SE", function()
        return fake:anyNonSilent()
      end, 60)
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

-- The 60 Hz semantic audio clock is wall-clock-owned by the runtime, not
-- field-tick-owned: a 60-frame BGM fade completes after exactly one second
-- of elapsed runtime time, with the same completion boundary under every
-- host update chunking (60 steps of 1/60, 30 steps of 1/30, and an
-- irregular schedule whose intervals are not field ticks and sum to one
-- second). No schedule may need 60 field ticks, because the field runs at
-- 30 Hz.
function T.tests.a_60_frame_fade_completes_after_one_wall_clock_second_for_every_dt_chunking()
  withProductionAudio(TOWN, day, function(game)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    Assert.equal(audio:currentMusic(), wakaba, "the map-header BGM must be running")

    local function runSchedule(label, schedule)
      audio:fadeMusicOut({ target = 50, durationTicks = 60 })
      Assert.isTrue(audio:isMusicFadeActive(), label .. ": the fade must start")
      -- Before the final 1/60 interval the fade is still active: a 30 Hz
      -- owner has advanced only 29 of the 60 frames at this point.
      for index = 1, #schedule - 1 do
        game.runtime:update(schedule[index])
      end
      Assert.isTrue(
        audio:isMusicFadeActive(),
        label .. ": the fade must still block before the final wall-clock interval"
      )
      game.runtime:update(schedule[#schedule])
      Assert.isFalse(
        audio:isMusicFadeActive(),
        label .. ": the 60-frame fade must complete after exactly one wall-clock second"
      )
      Assert.equal(audio:currentMusic(), wakaba, label .. ": the BGM reference must survive the fade")
      Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), label .. ": a fade never stops the BGM player")
      -- A fresh runtime second: the accumulator keeps running after the fade.
      game.runtime:update(1 / 60)
    end

    local sixtieths = {}
    for _ = 1, 60 do
      sixtieths[#sixtieths + 1] = 1 / 60
    end
    runSchedule("60 calls of 1/60", sixtieths)

    local thirtieths = {}
    for _ = 1, 30 do
      thirtieths[#thirtieths + 1] = 1 / 30
    end
    runSchedule("30 calls of 1/30", thirtieths)

    -- A deterministic irregular schedule: 30 sixtieths + 10 thirtieths + 20
    -- one-hundred-twentieths -- none of them a field tick -- summing to
    -- exactly one second (30/60 + 10/30 + 20/120 = 1).
    local irregular = {}
    for index = 1, 30 do
      irregular[#irregular + 1] = 1 / 60
    end
    for index = 1, 10 do
      irregular[#irregular + 1] = 1 / 30
    end
    for index = 1, 20 do
      irregular[#irregular + 1] = 1 / 120
    end
    runSchedule("irregular sub-tick schedule", irregular)
  end)
end

-- A fanfare's post-wait is measured in 60 Hz sound frames, not 30 Hz field
-- ticks: the fanfare stays active through the first 14 post-wait frames and
-- the 15th completes the state and resumes the current BGM. At 60 Hz that
-- is 0.25 seconds. The host update schedule deliberately does not equal one
-- field tick per sound frame (1/120 steps), so a field-tick owner cannot
-- satisfy the boundary.
function T.tests.a_fanfare_post_wait_lasts_15_sound_frames_not_field_ticks()
  withProductionAudio(TOWN, day, function(game)
    local audio = requireAudio(game)
    local wakaba = musicId(game, NEW_BARK_MUSIC)
    local fanfare = musicId(game, "SEQ_ME_ITEM")
    Assert.equal(audio:currentMusic(), wakaba, "the map-header BGM must be running")

    audio:playFanfare(fanfare)
    Assert.isTrue(audio:isFanfarePlaying(), "the fanfare must be playing")
    Assert.equal(audio:currentMusic(), wakaba, "the fanfare keeps the suspended BGM reference")

    -- Run the fanfare sequence itself to its end on the 60 Hz runtime clock
    -- (the fanfare player must be finished before the post-wait counts).
    game:advanceUntil("the fanfare player finishes", function()
      return not audio:isEffectPlaying(fanfare)
    end, 400)

    -- The post-wait is 15 sound frames, driven at 1/120 host steps (two host
    -- updates per sound frame, so no host update equals a field tick).
    -- Twenty-eight 1/120 updates advance exactly 14 sound frames: the fanfare
    -- must still be active.
    for _ = 1, 28 do
      game.runtime:update(1 / 120)
    end
    Assert.isTrue(audio:isFanfarePlaying(), "the fanfare post-wait must still hold through the first 14 sound frames")
    -- Two more 1/120 updates reach the 15th sound frame: the post-wait
    -- completes and the preserved BGM player resumes.
    for _ = 1, 2 do
      game.runtime:update(1 / 120)
    end
    Assert.isFalse(
      audio:isFanfarePlaying(),
      "the fanfare post-wait must complete at exactly 15 sound frames (0.25 seconds)"
    )
    Assert.equal(audio:currentMusic(), wakaba, "the resumed BGM is the suspended map music")
    Assert.isTrue(audio:isEffectPlaying(NEW_BARK_MUSIC), "the fanfare completion resumes the BGM player")
  end)
end

return T
