-- Private target facts for Epics 9/10 against a real HGSS dump: every
-- pre-script fixture key resolves to a real object/background event, the
-- fixture banks agree with the map-header associations, the background
-- fixture script families match the pinned zone-event JSON, and the
-- interaction resolver + pre-script adapter drive the Elm preview headless
-- with the real compiled font and banks (spec gates 8 and 9). Structural
-- facts only; no retail message text is printed.

local Assert = require("tests.support.Assert")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldFontCompiler = require("romdump.src.digest.FieldFontCompiler")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldMessageCompiler = require("romdump.src.digest.FieldMessageCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldObjectActor = require("libs.engine.src.FieldObjectActor")
local FieldScenario = require("libs.engine.src.FieldScenario")
local PreScriptInteractionAdapter = require("libs.engine.src.PreScriptInteractionAdapter")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local actorManifest = require("data.manifests.field_actors")
local fixtures = require("data.manifests.pre_script_interactions")
local scenarioManifest = require("data.manifests.field_scenario")

local T = {}

local LAB = 61
local TOWN = 60

local POLICY = {
  variableSpriteRange = actorManifest.variableSpriteRange,
  variableVarBase = actorManifest.variableVarBase,
}

local function maps(romFs)
  return {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
end

-- The manager with the compiled actor set under the deterministic scenario,
-- with a stub asset provider (the visual bundle is field_actors_test's
-- subject; lifecycle and interaction need only the acquire/release contract).
local function managerFor(romFs, map, mapsById)
  local reader = function(mapId)
    return assert(mapsById[mapId]).fieldData
  end
  local eventState = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, eventState, reader)
  local references = {}
  local assets = {
    knows = function()
      return true
    end,
    acquire = function(_, spriteId)
      references[spriteId] = (references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
    end,
    release = function(_, spriteId)
      references[spriteId] = assert(references[spriteId]) - 1
    end,
  }
  local manager = FieldActorManager.new({ assets = assets, policy = POLICY })
  manager:enterMap(map, eventState)
  return manager, eventState
end

local function surfaceAt(map, fieldX, fieldZ)
  return assert(SurfaceResolver.new(map.terrain):resolve({
    localX = fieldX - map.coordinateOrigin.x + 0.5,
    localZ = fieldZ - map.coordinateOrigin.z + 0.5,
    currentY = 0,
  }))
end

local function playerSnapshot(map, fieldX, fieldZ, facing, tick)
  local sample = surfaceAt(map, fieldX, fieldZ)
  return {
    runtimeMap = map,
    fieldX = fieldX,
    fieldZ = fieldZ,
    surfaceId = sample.surfaceId,
    worldY = sample.worldY,
    facing = facing,
    tick = tick,
  }
end

local function bankCache(romFs)
  local bundle = assert(FieldMessageCompiler.compile(romFs))
  return {
    bundle = bundle,
    loadLua = function(_, path)
      local bankId = path:match("banks/(%d+)%.lua$")
      return bankId and bundle.banks[tonumber(bankId)] or nil
    end,
  }
end

function T.fixture_keys_resolve_to_real_target_events(romFs)
  local all = maps(romFs)
  for key, fixture in pairs(fixtures) do
    local mapId, kind, identity = key:match("^map:(%d+):(%w+):(%d+)$")
    assert(mapId and kind, "malformed fixture key " .. key)
    local map = assert(all[tonumber(mapId)], "fixture " .. key .. " targets an unsupported map")
    local found = false
    if kind == "object" then
      for _, event in ipairs(map.fieldData.events.objects or {}) do
        if event.objectEventId == tonumber(identity) then
          found = true
        end
      end
    else
      for _, event in ipairs(map.fieldData.events.background or {}) do
        if event.index == tonumber(identity) then
          found = true
        end
      end
    end
    Assert.isTrue(found, "fixture key " .. key .. " does not resolve to a real event")
    Assert.isTrue(
      type(fixture.messageBankId) == "number" and type(fixture.messageId) == "number",
      "fixture " .. key .. " requires numeric message identity"
    )
    Assert.isTrue(
      fixture.facePlayer == nil or fixture.facePlayer == true or fixture.facePlayer == false,
      "fixture " .. key .. " facePlayer must be a boolean"
    )
    if fixture.substitutions then
      Assert.equal(
        type(fixture.substitutions.playerName),
        "string",
        "fixture " .. key .. " only supports the playerName substitution"
      )
    end
  end
end

function T.fixture_banks_match_the_map_header_association(romFs)
  local all = maps(romFs)
  Assert.equal(all[LAB].fieldData.messageBankId, 543)
  Assert.equal(all[LAB].fieldData.scriptBankId, 843)
  Assert.equal(all[TOWN].fieldData.messageBankId, 542)
  Assert.equal(all[TOWN].fieldData.scriptBankId, 842)
  for key, fixture in pairs(fixtures) do
    local mapId = tonumber(key:match("^map:(%d+)"))
    Assert.equal(
      fixture.messageBankId,
      all[mapId].fieldData.messageBankId,
      "fixture " .. key .. " bank must match its map's generated association"
    )
  end
end

-- The pinned 058_T20R0101.json stores scr_seq index N + 1: background events
-- 0/1 -> script 5, 2/3 -> script 6, 4/5 -> script 7, 6/7 -> script 8,
-- 8 -> script 9 (raw scriptIds 6..10), and event 10 -> the healing-PC script
-- 13 (raw 14). The fixtures must sit inside those families.
function T.background_fixture_script_families_match_the_pinned_json(romFs)
  local lab = assert(maps(romFs)[LAB])
  local expected = { [0] = 6, [2] = 7, [4] = 8, [6] = 9, [8] = 10, [10] = 14 }
  for key, _ in pairs(fixtures) do
    local mapId, kind, identity = key:match("^map:(%d+):(%w+):(%d+)$")
    if tonumber(mapId) == LAB and kind == "background" then
      local index = tonumber(identity)
      local actual = assert(expected[index], "fixture " .. key .. " is not in the documented background family")
      local event = lab.fieldData.events.background[index + 1]
      Assert.equal(event.scriptId, actual, "fixture " .. key .. " scriptId drifted from the pinned zone-event JSON")
    end
  end
end

function T.fixture_message_ids_are_in_range_for_their_banks(romFs)
  local cache = bankCache(romFs)
  local provider = assert(FieldMessageProvider.new(cache))
  for key, fixture in pairs(fixtures) do
    local bank = assert(
      provider:acquireBank(fixture.messageBankId),
      "fixture " .. key .. " references a bank outside the compiled set"
    )
    Assert.isTrue(
      fixture.messageId < bank.messageCount,
      "fixture "
        .. key
        .. " message "
        .. fixture.messageId
        .. " is out of range for bank "
        .. fixture.messageBankId
        .. " ("
        .. bank.messageCount
        .. " messages)"
    )
    provider:releaseBank(fixture.messageBankId)
  end
end

function T.resolver_resolves_the_lab_object_and_background_targets_on_real_data(romFs)
  local all = maps(romFs)
  local lab = all[LAB]
  local manager = managerFor(romFs, lab, all)
  local resolver = FieldInteractionResolver.new({
    actorAt = function(mapId, x, z, surfaceId)
      return manager:getAt(mapId, x, z, surfaceId)
    end,
  })

  -- Stand south of Elm (object 0 at (6,5)) facing north.
  local elm = assert(resolver:resolve(playerSnapshot(lab, 6, 6, "north", 1)))
  Assert.equal(elm.kind, "object")
  Assert.equal(elm.object.objectEventId, 0)
  Assert.equal(elm.scriptId, 1)
  Assert.equal(elm.scriptBankId, 843)

  -- Stand north of the aide (object 2 at (9,12)) facing south.
  local aide = assert(resolver:resolve(playerSnapshot(lab, 9, 11, "south", 2)))
  Assert.equal(aide.kind, "object")
  Assert.equal(aide.object.objectEventId, 2)
  Assert.equal(aide.scriptId, 2)

  -- Stand south of the healing PC background event (index 10 at (4,3))
  -- facing north: no actor occupies the cell, so the background wins.
  local pc = assert(resolver:resolve(playerSnapshot(lab, 4, 4, "north", 3)))
  Assert.equal(pc.kind, "background")
  Assert.equal(pc.background.eventIndex, 10)
  Assert.equal(pc.scriptId, 14)

  -- A wrong-facing background must not resolve: the PC needs dir 0.
  Assert.isNil(resolver:resolve(playerSnapshot(lab, 4, 4, "south", 4)))
  manager:dispose()
end

function T.town_resident_interaction_resolves_on_real_data(romFs)
  local all = maps(romFs)
  local town = all[TOWN]
  local manager = managerFor(romFs, town, all)
  local resolver = FieldInteractionResolver.new({
    actorAt = function(mapId, x, z, surfaceId)
      return manager:getAt(mapId, x, z, surfaceId)
    end,
  })
  -- Stand south of the woman resident (object 1 at (683,399)) facing north.
  local intent = resolver:resolve(playerSnapshot(town, 683, 400, "north", 1))
  assert(intent, "the woman resident must resolve as an object intent")
  Assert.equal(intent.kind, "object")
  Assert.equal(intent.object.objectEventId, 1)
  -- Raw scriptId 2 = scr_seq index 1 (scr_seq_T20_001), which shows message 9.
  Assert.equal(intent.scriptId, 2)
  manager:dispose()
end

-- The full adapter path with the real compiled font, banks, and actors:
-- intent -> fixture -> formatted message -> facing override -> modal
-- dialogue -> completion releases everything exactly once.
function T.adapter_drives_the_elm_preview_end_to_end(romFs)
  local all = maps(romFs)
  local lab = all[LAB]
  local manager, eventState = managerFor(romFs, lab, all)
  local font = assert(FieldFontCompiler.compile(romFs, Hashing.sha1hex, Hashing.hashLua)).font
  local cache = bankCache(romFs)
  local provider = assert(FieldMessageProvider.new(cache, { maxCachedBanks = 2 }))
  local metrics = FieldDialogueTheme.fontMetrics(font)
  local layout = function(message)
    return DialogueLayout.layout(
      message.tokens,
      metrics,
      { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
    )
  end
  local dialogue = FieldDialogueController.new({ layout = layout })
  local adapter = PreScriptInteractionAdapter.new({
    dialogue = dialogue,
    provider = provider,
    layout = layout,
    fontDef = font,
    getActor = function(actorId)
      return manager:getById(actorId)
    end,
    mapMessageBank = function(mapId)
      return lab.fieldData.messageBankId
    end,
    fixtures = fixtures,
  })

  local elmActor = assert(manager:getById("map:61:object:0"))
  ---@type FieldObjectActor
  local elm = assert(manager:getAt(61, 6, 5, elmActor.surfaceId))
  local resolver = FieldInteractionResolver.new({
    actorAt = function(mapId, x, z, surfaceId)
      return manager:getAt(mapId, x, z, surfaceId)
    end,
  })
  local intent = assert(resolver:resolve(playerSnapshot(lab, 6, 6, "north", 1)))
  Assert.equal(intent.object.actorId, "map:61:object:0")

  local consumed = adapter:consume(intent)
  Assert.equal(consumed, true)
  Assert.isTrue(dialogue:isModal())
  Assert.equal(dialogue:status().requestId, "pre-script-map:61:object:0")
  Assert.equal(elm.interactionFacingOverride.owner, "pre-script-dialogue")

  local result
  local ticks = 0
  while dialogue:isModal() and ticks < 1000 do
    result = dialogue:step({ actionPressed = true })
    ticks = ticks + 1
  end
  Assert.isTrue(ticks < 1000, "the Elm preview closes within 1000 ticks")
  Assert.equal(assert(result).kind, "complete")
  Assert.equal(assert(result).metadata.interactionIntent.object.actorId, "map:61:object:0")
  Assert.isNil(elm.interactionFacingOverride, "the override releases on completion")
  Assert.equal(elm.facing, elm.initialFacing, "the prior facing is restored")
  Assert.equal(provider:stats().references, 0, "the bank reference releases")
  provider:dispose()
  manager:dispose()
end

function T.no_target_map_has_ambiguous_eligible_background_duplicates(romFs)
  -- The resolver picks the first eligible candidate in source order; the
  -- target maps must not contain two eligible duplicates on one facing cell
  -- (spec section 12.3), or the choice would be ambiguous.
  local all = maps(romFs)
  for _, map in pairs(all) do
    local cells = {}
    for _, event in ipairs(map.fieldData.events.background or {}) do
      if event.type ~= 2 then
        local key = event.x .. ":" .. event.z
        cells[key] = (cells[key] or 0) + 1
      end
    end
    for key, count in pairs(cells) do
      Assert.equal(
        count,
        1,
        "map " .. map.mapId .. " cell " .. key .. " has " .. count .. " eligible background events"
      )
    end
  end
end

return T
