-- Field-map audio policy compilation contract. FieldMapDataCompiler must turn
-- the frozen field-audio reference facts and each map's land BGS soundplate
-- payload into the semantic part of the generated field record: the canonical
-- day/night references stay, the music record gains the source flag overrides
-- (exactly the thirteen rules, attached only to their maps) and the surfing
-- traversal override, and the soundplates array carries semantic records whose
-- raw soundplateSoundID/unknown bytes never reach the runtime. Records also
-- emit the source BGM duck and ambient targets from the volume index and the
-- four disable conditions per FieldSystem_SoundplateIsActive scope. Each
-- scenario compiles a synthetic map through the real production compiler.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local Fixture = require("tests.support.FieldMapDataFixture")
local Builder = require("tests.support.SoundplateBuilder")
local fieldAudio = require("romdump.src.reference.hgss.field_audio")

local T = {}

local function compile(payload, map)
  map = map or 60
  local romFs = Fixture.build({ landBgsPayload = payload })
  return FieldMapDataCompiler.compile(romFs, map)
end

local function compileOk(payload, map)
  local bundle, err = compile(payload, map)
  Assert.isTrue(bundle ~= nil, "compile failed: " .. tostring(err and err.message or err))
  return assert(bundle)
end

-- The disable scope of FieldSystem_SoundplateIsActive, derived from the single
-- frozen reference authority (field_audio.lua): each soundplate entry carries
-- its disableWhen {flagId, map?} metadata -- a map-scoped rule applies only on
-- its named map, an unscoped rule on every map carrying that sound. The tests
-- never maintain a second copy of the four rule constants.
local function expectedDisableFlag(id, mapSymbol)
  local rule = fieldAudio.soundplates[id + 1].disableWhen
  if rule ~= nil and (rule.map == nil or rule.map == mapSymbol) then
    return rule.flagId
  end
  return nil
end

function T.music_record_carries_day_night_overrides_and_the_surf_traversal_rule()
  local bundle = compileOk("")
  Assert.equal(bundle.field.schema, "g4-field-map-v8")
  Assert.deepEqual(bundle.field.music, {
    day = "SEQ_GS_T_WAKABA",
    night = "SEQ_GS_T_WAKABA",
    flagOverrides = {},
    traversalOverrides = fieldAudio.traversalOverrides,
  })
  Assert.deepEqual(bundle.field.soundplates, {})
end

function T.flag_overrides_attach_exactly_the_thirteen_source_rules_to_their_maps()
  for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
    local bundle = compileOk("", rule.map)
    Assert.deepEqual(bundle.field.music.flagOverrides, { { flagId = rule.flagId, sequence = rule.sequence } }, rule.map)
  end
  -- MAP_NOTHING (id 1) is a catalog placeholder with no field data (mapType
  -- "INVALID"); it is excluded from the field-map pipeline entirely and is
  -- never a direct compile target, so it is not part of this negative check.
  for _, mapId in ipairs({ 2, 5, 60, 61, 100 }) do
    local bundle = compileOk("", mapId)
    Assert.deepEqual(bundle.field.music.flagOverrides, {}, "map " .. mapId .. " must not carry a foreign rule")
  end
end

function T.all_sixteen_sounds_compile_semantic_records_without_raw_ids()
  local records = {}
  for id = 0, 15 do
    records[id + 1] = { soundId = id, volumeIndex = 0, x = id, z = 31 - id, xBounds = 20, zBounds = 24 }
  end
  local bundle = compileOk(Builder.records({ records = records }), "MAP_NEW_BARK")
  local plates = bundle.field.soundplates
  Assert.equal(#plates, 16)
  for id = 0, 15 do
    local ref = fieldAudio.soundplates[id + 1]
    local mapSymbol = bundle.field.mapSymbol
    Assert.deepEqual(plates[id + 1], {
      x = id,
      z = 31 - id,
      xBounds = 20,
      zBounds = 24,
      sequence = ref.sequence,
      useFieldMusicBank = ref.useFieldMusicBank,
      bgmTarget = fieldAudio.bgmDuckTargets[1],
      ambientTarget = ref.ambientLevels[1],
      disabledWhenFlag = expectedDisableFlag(id, mapSymbol),
    }, "sound id " .. id)
  end
  Assert.isNil(bundle.field.soundplates[1].soundplateSoundID, "a raw sound id never reaches the runtime asset")
  Assert.isNil(bundle.field.soundplates[1].volumeIndex, "the raw volume index never reaches the runtime asset")
end

function T.volume_index_emits_duck_and_ambient_targets_or_nothing_above_two()
  local records = {}
  for volumeIndex = 0, 3 do
    records[volumeIndex + 1] = {
      soundId = 3,
      volumeIndex = volumeIndex,
      x = volumeIndex,
      z = 0,
      xBounds = 1,
      zBounds = 1,
    }
  end
  local bundle = compileOk(Builder.records({ records = records }))
  local ref = fieldAudio.soundplates[4]
  Assert.equal(ref.sequence, "SEQ_SE_GS_N_HASHIRA")
  for volumeIndex = 0, 3 do
    local plate = bundle.field.soundplates[volumeIndex + 1]
    Assert.isNil(plate.volumeIndex, "the raw volume index never reaches the runtime asset")
    if volumeIndex >= 3 then
      Assert.isNil(plate.bgmTarget, "volume index " .. volumeIndex .. " emits no bgm duck")
      Assert.isNil(plate.ambientTarget, "volume index " .. volumeIndex .. " emits no ambient move")
    else
      Assert.equal(plate.bgmTarget, fieldAudio.bgmDuckTargets[volumeIndex + 1])
      Assert.equal(plate.ambientTarget, ref.ambientLevels[volumeIndex + 1])
    end
  end
end

function T.disable_flags_follow_the_source_map_and_sound_scope()
  local record = function(soundId)
    return { soundId = soundId, volumeIndex = 0, x = 0, z = 0, xBounds = 4, zBounds = 4 }
  end

  local cianwoodWaterfall = compileOk(Builder.records({ records = { record(5) } }), "MAP_CIANWOOD_GYM")
  Assert.equal(cianwoodWaterfall.field.soundplates[1].disabledWhenFlag, (expectedDisableFlag(5, "MAP_CIANWOOD_GYM")))
  local newBarkWaterfall = compileOk(Builder.records({ records = { record(5) } }), "MAP_NEW_BARK")
  Assert.isNil(newBarkWaterfall.field.soundplates[1].disabledWhenFlag, "waterfall outside Cianwood stays live")
  local cianwoodFlow = compileOk(Builder.records({ records = { record(0) } }), "MAP_CIANWOOD_GYM")
  Assert.isNil(cianwoodFlow.field.soundplates[1].disabledWhenFlag, "only the specific sound is gated")

  local vermilionBarrier = compileOk(Builder.records({ records = { record(15) } }), "MAP_VERMILION_GYM")
  Assert.equal(vermilionBarrier.field.soundplates[1].disabledWhenFlag, (expectedDisableFlag(15, "MAP_VERMILION_GYM")))
  local newBarkBarrier = compileOk(Builder.records({ records = { record(15) } }), "MAP_NEW_BARK")
  Assert.isNil(newBarkBarrier.field.soundplates[1].disabledWhenFlag, "electric barrier outside Vermilion stays live")

  local snorlax = compileOk(Builder.records({ records = { record(9) } }), "MAP_NEW_BARK")
  Assert.equal(snorlax.field.soundplates[1].disabledWhenFlag, 0xF9, "snorlax snoring is gated by sound on any map")
  local motor = compileOk(Builder.records({ records = { record(10) } }), "MAP_NEW_BARK")
  Assert.equal(motor.field.soundplates[1].disabledWhenFlag, 0xCA, "rocket motor is gated by sound on any map")
end

function T.invalid_source_sound_id_fails_compile_with_attributed_context()
  local payload = Builder.records({
    records = {
      { soundId = 16, volumeIndex = 0, x = 0, z = 0, xBounds = 1, zBounds = 1 },
    },
  })
  local bundle, err = compile(payload, 60)
  Assert.isNil(bundle)
  Assert.notNil(err)
  local e = assert(err)
  Assert.deepEqual(
    { code = e.code, mapId = e.context.mapId, recordIndex = e.context.recordIndex, sound = e.context.soundplateSoundID },
    { code = "FIELD_MAP_UNKNOWN_SOUNDPLATE_SOUND", mapId = 60, recordIndex = 0, sound = 16 }
  )
end

return { tests = T }
