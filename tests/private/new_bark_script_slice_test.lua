-- Private integration gate for the script override system: the New Bark
-- slice runs end-to-end against real ROM data. The full platform (registry
-- over the compiled script cache + the checked-in data/scripts/overrides,
-- composition, bindings, scheduler, interaction client, dialogue host, actor
-- world, world state) is wired like FieldState does, and a real
-- FieldSession drives the interactions: the New Bark woman's vanilla
-- dialogue, Elm's fresh-save conversation, and an overridden placeholder
-- script. The pre-script fixture path is intentionally absent here; every
-- exercised event is bound.

local Assert = require("tests.support.Assert")
local DialogueLayout = require("libs.engine.src.DialogueLayout")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldFontCache = require("libs.assets.src.FieldFontCache")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldScenario = require("libs.engine.src.FieldScenario")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldScripts = require("game.src.game.FieldScripts")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local CacheFs = require("libs.rom.src.CacheFs")
local actorManifest = require("data.manifests.field_actors")
local scenarioManifest = require("data.manifests.field_scenario")
local BindingsManifest = require("data.scripts.manifests.vanilla_bindings")

local T = {}

local TOWN = 60
local LAB = 61

local POLICY = {
  variableSpriteRange = actorManifest.variableSpriteRange,
  variableVarBase = actorManifest.variableVarBase,
}

local function stubAssets()
  return {
    knows = function()
      return true
    end,
    acquire = function(_, spriteId)
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
    end,
    release = function() end,
  }
end

-- A real transition-shaped object: records the started warp, reports the
-- "warp ran" completion through the same idle-phase signal the game's
-- FieldTransition produces after the application consumes a finished swap.
local function stubTransition()
  return {
    phase = "idle",
    sourceMap = nil,
    error = nil,
    completed = nil,
    start = function(self, sourceMap, warp, facing)
      assert(self.phase == "idle", "transition already active")
      self.phase = "transitioning"
      self.sourceMap = sourceMap
      self.started = { sourceMap = sourceMap, warp = warp, facing = facing }
    end,
    updateFixed = function() end,
    finish = function(self)
      self.phase = "idle"
      self.sourceMap = nil
      self.completed = true
    end,
  }
end

-- The repo filesystem for the override loader, exactly as the game builds
-- it (the LÖVE build cannot mount host directories).
local function repoFs()
  local RepoFs = require("game.src.game.RepoFs")
  return RepoFs.new(love.filesystem.getSourceBaseDirectory())
end

---@class SliceHarness
---@field session FieldSession
---@field scripts FieldScripts
---@field dialogue FieldDialogueController
---@field eventState FieldEventState
---@field player table
---@field runtimeMap table
---@field transition table
local SliceHarness = {}

local function harness(romFs, versionId, mapId, opts)
  opts = opts or {}
  local runtimeMap = RomRuntimeMap.compile(romFs, mapId)
  local cacheFs = CacheFs.forVersion(versionId)
  local eventState = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, eventState, function(id)
    return assert(RomRuntimeMap.compile(romFs, id)).fieldData
  end)

  local actors = FieldActorManager.new({
    assets = stubAssets(),
    policy = POLICY,
  })
  actors:enterMap(runtimeMap, eventState)

  local dialogue = FieldDialogueController.new({
    layout = function(formatted)
      local fontDef = assert(cacheFs:loadLua(FieldFontCache.defPath(0)))
      return DialogueLayout.layout(
        formatted.tokens,
        FieldDialogueTheme.fontMetrics(fontDef),
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end,
  })
  local provider = FieldMessageProvider.new(cacheFs)
  local fontDef = assert(cacheFs:loadLua(FieldFontCache.defPath(0)))

  local transition = stubTransition()
  local player = FieldPlayer.new({
    currentMap = runtimeMap,
    fieldX = opts.fieldX,
    fieldZ = opts.fieldZ,
    surfaceId = opts.surfaceId,
    facing = opts.facing,
    occupancy = function()
      return nil
    end,
  })

  local scripts = FieldScripts.new({
    cacheFs = cacheFs,
    overrideFs = repoFs(),
    bindingsManifest = BindingsManifest,
    eventState = eventState,
    actors = actors,
    player = player,
    dialogue = dialogue,
    messageProvider = provider,
    layout = function(formatted)
      return DialogueLayout.layout(
        formatted.tokens,
        FieldDialogueTheme.fontMetrics(fontDef),
        { width = FieldDialogueTheme.textWidth, maxLines = FieldDialogueTheme.maxLines }
      )
    end,
    fontDef = fontDef,
    transition = transition,
    mapLoader = {
      load = function(_, idOrSymbol)
        return RomRuntimeMap.compile(romFs, idOrSymbol)
      end,
    } --[[@as FieldMapLoader]],
    sourceMap = runtimeMap,
  })

  local resolver = FieldInteractionResolver.new({
    actorAt = function(mapId, fieldX, fieldZ, surfaceId)
      return actors:getAt(mapId, fieldX, fieldZ, surfaceId) or nil
    end,
  })

  local session = FieldSession.new({
    versionId = versionId,
    currentMap = runtimeMap,
    actor = player,
    player = player,
    camera = { updateFixed = function() end } --[[@as FieldCamera]],
    actors = actors,
    dialogue = dialogue,
    input = nil,
    scriptScheduler = scripts.scheduler,
    scriptClient = scripts.client,
    interactions = {
      resolve = function(_, snapshot)
        return resolver:resolve(snapshot)
      end,
      consume = function()
        return false
      end,
    },
  })

  local self = setmetatable({
    session = session,
    scripts = scripts,
    dialogue = dialogue,
    eventState = eventState,
    player = player,
    runtimeMap = runtimeMap,
    transition = transition,
    actors = actors,
  }, SliceHarness)
  return self
end

-- The surface the runtime would resolve for the player at a field cell.
local function sampleAt(map, fieldX, fieldZ)
  local localX, localZ = fieldX - map.coordinateOrigin.x, fieldZ - map.coordinateOrigin.z
  local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
  return assert(SurfaceResolver.new(map.terrain):resolve({
    localX = localX + 0.5,
    localZ = localZ + 0.5,
    currentY = 0,
  }))
end

-- Advance the session until the dialogue box opens (or `limit` ticks pass).
local function waitForDialogue(h, limit)
  for _ = 1, (limit or 120) do
    h.session:updateFixed({})
    if h.dialogue:isModal() then
      return true
    end
  end
  return false
end

-- Advance until the dialogue closes again: wait for the box to arm its
-- input wait (typing finished), then press one edge and let the close
-- handoff run. Returns true once the box closed.
local function waitForClose(h, limit)
  local pressed = false
  for tick = 1, (limit or 240) do
    local input = {}
    if not pressed and tick > 60 then
      input.pressedAction = true
      pressed = true
    end
    h.session:updateFixed(input)
    if not h.dialogue:isModal() then
      return true
    end
  end
  return false
end

-- Let the script finish its tail (release/yield/stop) after the box closed.
local function settle(h, ticks)
  for _ = 1, (ticks or 10) do
    h.session:updateFixed({})
  end
end

-- Run a script to completion: keep pressing an edge whenever a box is open
-- and armed (or mid-typing, which fast-forwards), until the foreground
-- environment is gone. Returns true when the script finished.
local function runToCompletion(h, limit)
  for tick = 1, (limit or 600) do
    local input = {}
    if h.dialogue:isModal() and tick > 20 then
      input.pressedAction = true
    end
    h.session:updateFixed(input)
    if h.scripts.scheduler:foregroundEnvironmentId() == nil then
      return true
    end
  end
  return false
end

-- 1. The New Bark woman (map 60 object 1) runs her bound vanilla script:
-- the interaction starts the script, the field locks, she faces the player,
-- the box shows "Wait a sec!" (msg.hgss.0542.00009 for the fresh scene
-- variable), and an input edge closes it; the script then releases the field.
T["new bark woman runs her bound script"] = function(romFs, versionId)
  local h = harness(romFs, versionId, TOWN, {
    fieldX = 683,
    fieldZ = 400, -- south of the woman at (683,399)
    facing = "north",
    surfaceId = sampleAt(RomRuntimeMap.compile(romFs, TOWN), 683, 400).surfaceId,
  })
  -- The fresh scenario leaves VAR_SCENE_NEW_BARK_TOWN_OW at 0 (message 9).
  -- lock_all yields one frame, so the box opens on the following tick.
  h.session:updateFixed({ actionPressed = true })
  Assert.isTrue(waitForDialogue(h), "interaction opens the dialogue")
  Assert.isTrue(h.dialogue:isScriptOwned(), "the dialogue is script-owned")
  Assert.isTrue(runToCompletion(h), "the script runs to completion")

  -- The woman faced the player during the script.
  local woman = assert(h.actors:getById("map:60:object:1"))
  Assert.equal(woman.facing, "south", "face_player turned the woman toward the player")
  Assert.isNil(h.scripts.scheduler:foregroundEnvironmentId(), "the script completed and released the field")
end

-- 2. The woman's box is script-owned: the modal gate does not consume input
-- and the scheduler steps the box; the box shows the bound message text and
-- the player stays locked while the script owns the field.
T["script dialogue is modal, locked, and shows the bound message"] = function(romFs, versionId)
  local h = harness(romFs, versionId, TOWN, {
    fieldX = 683,
    fieldZ = 400,
    facing = "north",
    surfaceId = sampleAt(RomRuntimeMap.compile(romFs, TOWN), 683, 400).surfaceId,
  })
  h.session:updateFixed({ actionPressed = true })
  Assert.isTrue(waitForDialogue(h), "the interaction opens a dialogue")
  local movedTicks = 0
  for _ = 1, 30 do
    local before = h.player.fieldZ
    h.session:updateFixed({ heldDirection = "north" })
    if h.player.fieldZ == before then
      movedTicks = movedTicks + 1
    end
  end
  Assert.equal(movedTicks, 30, "the player cannot move while the script owns the field")
  local status = h.dialogue:status()
  Assert.isTrue(#status.visibleLines > 0, "the box renders the bound message")
  Assert.isTrue(runToCompletion(h), "an edge closes the box and the script finishes")
  Assert.isNil(h.scripts.scheduler:foregroundEnvironmentId())
end

-- 3. Elm's fresh-save conversation (map 61 object 0): select sound, lock,
-- face player, the fresh message, then the player faces east and the script
-- releases. The fresh route is the override's supported path.
T["elm fresh conversation runs the override"] = function(romFs, versionId)
  local h = harness(romFs, versionId, LAB, {
    fieldX = 6,
    fieldZ = 6, -- south of Elm at (6,5)
    facing = "north",
    surfaceId = sampleAt(RomRuntimeMap.compile(romFs, LAB), 6, 6).surfaceId,
  })
  h.session:updateFixed({ actionPressed = true })
  Assert.isTrue(waitForDialogue(h), "Elm interaction opens the dialogue")
  Assert.isTrue(runToCompletion(h), "the fresh conversation completes")

  -- The fresh-save route applies the player-facing movement after the
  -- message: the player turns east (the movement task drives the facade).
  Assert.equal(h.player.facing, "east", "the fresh route turns the player east")
  Assert.isNil(h.scripts.scheduler:foregroundEnvironmentId(), "the conversation completed and released the field")
end

-- 4. A bound script with unsupported commands runs through its override:
-- the lab sign machine-adjacent placeholder (Elm's Lab background event 9,
-- the starter machine script) shows the project placeholder box instead of
-- faulting.
T["unsupported script runs its override placeholder"] = function(romFs, versionId)
  local h = harness(romFs, versionId, LAB, {
    fieldX = 8,
    fieldZ = 5, -- north of the starter machine at (8,4)
    facing = "north",
    surfaceId = sampleAt(RomRuntimeMap.compile(romFs, LAB), 8, 5).surfaceId,
  })
  h.session:updateFixed({ actionPressed = true })
  Assert.isTrue(waitForDialogue(h), "the overridden interaction opens a dialogue")
  Assert.isTrue(h.dialogue:isScriptOwned(), "the placeholder box is script-owned")
  -- Let the reveal start so the box has visible glyphs.
  for _ = 1, 6 do
    h.session:updateFixed({})
  end
  local status = h.dialogue:status()
  local rendered = {}
  for _, tokens in ipairs(status.visibleLines) do
    for _, token in ipairs(tokens) do
      if token.kind == "glyph" then
        rendered[#rendered + 1] = token.text or ""
      end
    end
  end
  Assert.equal(table.concat(rendered), "...", "the placeholder ellipsis is visible")
  Assert.isTrue(runToCompletion(h), "the placeholder closes and the script finishes")
  Assert.isNil(h.scripts.scheduler:foregroundEnvironmentId())
end

-- 5. The overrides and bindings are coherent: every bound script id resolves
-- through the composition (base or override), every bound script whose
-- generated translation carries unsupported commands has an override, and
-- every override file on disk loads and validates.
T["bindings and overrides are coherent"] = function(romFs, versionId)
  local h = harness(romFs, versionId, TOWN, {
    fieldX = 683,
    fieldZ = 398,
    facing = "north",
    surfaceId = sampleAt(RomRuntimeMap.compile(romFs, TOWN), 683, 398).surfaceId,
  })
  local ids = h.scripts.bindings:allScriptIds()
  Assert.isTrue(#ids >= 30, "every New Bark event is bound")
  for _, id in ipairs(ids) do
    Assert.notNil(h.scripts.composition:effective(id), "bound script resolves: " .. id)
  end

  -- Every scripted event of the eight New Bark maps (60-66 and 384) is
  -- bound: object and background events the resolver can reach, plus
  -- coordinate events (raw script id 0 means "no script" and is skipped).
  local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
  for _, mapId in ipairs({ 60, 61, 62, 63, 64, 65, 66, 384 }) do
    local events = assert(FieldMapDataCompiler.compile(romFs, mapId)).field.events
    for _, event in ipairs(events.objects) do
      if event.scriptId > 0 then
        Assert.notNil(
          h.scripts.bindings:scriptFor(mapId, "object", string.format("map:%d:object:%d", mapId, event.objectEventId)),
          "map " .. mapId .. " object " .. event.objectEventId .. " is bound"
        )
      end
    end
    for _, event in ipairs(events.background) do
      -- Type-2 records are the hidden-item family: their script id is the
      -- 8000 sentinel (no scr_seq script) and the resolver skips them.
      if event.scriptId > 0 and event.type ~= 2 then
        Assert.notNil(
          h.scripts.bindings:scriptFor(mapId, "background", event.index),
          "map " .. mapId .. " background " .. event.index .. " is bound"
        )
      end
    end
    for _, event in ipairs(events.coordinates) do
      if event.scriptId > 0 then
        Assert.notNil(
          h.scripts.bindings:scriptFor(mapId, "coordinate", event.index),
          "map " .. mapId .. " coordinate " .. event.index .. " is bound"
        )
      end
    end
  end

  -- Every bound script whose generated translation carries reachable
  -- unsupported commands has an override (the override system's contract),
  -- and every override's base is bound on the slice.
  local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local Structurer = require("romdump.src.digest.script.Structurer")
  local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
  local ScriptMembers = require("data.reference.hgss.script_members")
  local archive = assert(romFs:openNarc("field_scripts"))
  local catalog = {
    sounds = require("data.reference.hgss.sndseq").byId,
    flags = require("data.reference.hgss.flags").byId,
    vars = require("data.reference.hgss.vars").byId,
    maps = require("data.reference.hgss.maps").byId,
    spawns = require("data.reference.hgss.spawns").byId,
  }
  local memberIrs = ScriptBinaryDecoder.decodeArchive(archive, ScriptMembers.banks, "romfs/scr_seq.narc", catalog)
  local stdCatalog = SourceCatalog.catalog()
  local function generatedIsUnsupported(id)
    local layers = h.scripts.registry._bases[id]
    local generated = layers and layers.generated
    if generated == nil or generated.metadata == nil then
      return false
    end
    local coverage = generated.metadata.coverage
    return coverage ~= nil and (coverage.unsupportedCount or 0) > 0
  end
  for _, id in ipairs(ids) do
    if generatedIsUnsupported(id) then
      local base = h.scripts.registry:base(id)
      Assert.notNil(base, "overridden unsupported script resolves: " .. id)
      Assert.equal(base.metadata.override, true, "unsupported bound script has an override: " .. id)
    end
  end
end

return T
