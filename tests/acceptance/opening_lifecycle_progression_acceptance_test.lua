-- Production-composed contracts for the Player House 1F Mom opening scene,
-- its New Bark friend/Marill follow-up, lifecycle arbitration under a
-- faulted foreground owner, and the Start Menu policy bridge. Real
-- ROM-derived maps, scripts, and the scheduler stay in the path; only host
-- boundaries (audio, script effect/event recording) are faked.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local OpeningLifecycle = require("tests.acceptance.support.OpeningLifecycle")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local StartMenuPolicy = require("libs.engine.src.StartMenuPolicy")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "lifecycle", "opening", "start-menu" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local HOUSE_1F = "MAP_NEW_BARK_PLAYER_HOUSE_1F"
local TOWN_HOUSE_DOOR_APPROACH = { fieldX = 695, fieldZ = 397 }
local VAR_SCENE_PLAYERS_HOUSE_1F = OpeningLifecycle.VAR_SCENE_PLAYERS_HOUSE_1F
local FLAG_HIDE_NEW_BARK_FRIEND = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_FRIEND
local FLAG_HIDE_NEW_BARK_MARILL = FieldScriptSymbols.flagsByName.FLAG_HIDE_NEW_BARK_MARILL

local function withGame(map, fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = map,
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "opening-lifecycle acceptance must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function recordsNamed(game, name)
  local records = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == name then
      records[#records + 1] = record
    end
  end
  return records
end

-- Enter Player House 1F through the real production town door, exactly as
-- an ordinary player would.
local function enterHouse(game)
  game:moveTo(TOWN_HOUSE_DOOR_APPROACH)
  game:step({ direction = "north" })
  local transition = game:waitForTransition()
  Assert.equal(transition.destination.mapSymbol, HOUSE_1F)
end

-- Repeatedly press-and-release within the same tick, retrying until the
-- application host observes the edge; a single upfront press can be
-- discarded while the map-entry lifecycle still owns input.
local function openMenu(game)
  game:waitForFieldEntry()
  for _ = 1, 60 do
    local status = game.runtime.applicationHost:status()
    if status.menu then
      return status.menu
    end
    game.runtime:pressMenu()
    game:step()
    game.runtime:releaseMenu()
  end
  error("the start menu did not open")
end

local function closeMenu(game)
  for _ = 1, 60 do
    local status = game.runtime.applicationHost:status()
    if not status.menu then
      return
    end
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
  end
  error("the start menu did not close")
end

local function actionById(menu, id)
  for _, action in ipairs(menu.actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

-- The exact source facts FieldRuntime itself reads to compose the Start
-- Menu (game/src/game/FieldRuntime.lua:_composeStartMenu). Reused here only
-- to observe the pure source-enablement gate directly: the application
-- host's composed `enabled` field also requires the destination
-- application to be implemented, which conflates unrelated
-- implementation-completeness with the source flag gate this scenario is
-- about (Options has no implemented destination application in this port).
local function sourcePolicyActionById(world, id)
  local flags = FieldScriptSymbols.flagsByName
  local actions = StartMenuPolicy.actions({
    hasPokedex = world:isFlagSet(flags.FLAG_GOT_POKEDEX),
    hasStarter = world:isFlagSet(flags.FLAG_GOT_STARTER),
    bagUnlocked = world:isFlagSet(flags.FLAG_GOT_BAG),
    hasPokegear = world:isFlagSet(flags.FLAG_GOT_POKEGEAR),
    trainerCardUnlocked = world:isFlagSet(flags.FLAG_GOT_TRAINER_CARD),
    saveUnlocked = world:isFlagSet(flags.FLAG_GOT_SAVE_BUTTON),
    optionsUnlocked = world:isFlagSet(flags.FLAG_GOT_OPTIONS_BUTTON),
  })
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

function T.tests.house_mom_scene_advances_the_opening_state()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 0, "a genuinely fresh world starts at scene value 0")

    -- Let TOWN's own unconditional on_transition/on_resume lifecycle settle
    -- first; only script activity from here on belongs to the House 1F
    -- opening scene under test.
    game:waitForFieldEntry()
    local baselineStarts = #recordsNamed(game, "script.started")
    local baselineEnds = #recordsNamed(game, "script.ended")

    enterHouse(game)
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 0),
      "generated House 1F rules must have a script for scene value 0"
    )

    -- The generated on-frame lifecycle rule must start the source scene
    -- script before normal player movement can proceed; exactly one
    -- foreground script owns the field during the sequence.
    game:advanceUntil("the opening scene starts", function()
      return #recordsNamed(game, "script.started") > baselineStarts
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(#starts - baselineStarts, 1, "the opening scene must start exactly one foreground script")
    Assert.equal(
      starts[baselineStarts + 1].payload.scriptId,
      expectedSceneScriptId,
      "the generated scene-0 script must own the field"
    )
    Assert.isTrue(
      game.runtime.scripts.scheduler:foregroundEnvironmentId() ~= nil,
      "the scene script must own the field"
    )

    OpeningLifecycle.completeOpeningHouseScene(game)

    for _, flag in ipairs(OpeningLifecycle.MOM_GRANTED_FLAGS) do
      Assert.isTrue(world:isFlagSet(flag), "the Mom scene must grant every early progression flag")
    end
    Assert.equal(world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F), 1, "the Mom scene must advance the scene variable")
    Assert.isNil(game.runtime.scripts.scheduler:foregroundEnvironmentId(), "ReleaseAll must return field ownership")

    -- The root scene script also runs CallStd children (play/fade the Mom
    -- music); filter to the scene script's own end record, not its children.
    local sceneEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneEnds[#sceneEnds + 1] = record
      end
    end
    Assert.equal(#sceneEnds, 1, "the scene script must end exactly once")
    Assert.isTrue(sceneEnds[1].payload.completed, "the scene script must end by normal completion, not a fault")

    -- The predicate is no longer true (scene value is now 1, not 0), so the
    -- same frame rule must not restart on subsequent idle ticks.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfterCompletion = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfterCompletion = sceneStartsAfterCompletion + 1
      end
    end
    Assert.equal(sceneStartsAfterCompletion, 1, "the completed opening scene must not restart")
  end, { recordingScriptHosts = true })
end

function T.tests.new_bark_friend_and_marill_scene_follows_the_house_scene()
  withGame(TOWN, function(game)
    -- Documented post-opening precondition: the House 1F Mom scene reaching
    -- this state through real script execution is covered separately above.
    -- This scenario is about New Bark's own on_transition/on_frame_eq
    -- handoff, so it seeds the same source scene value the Mom scene
    -- produces, before the very first tick (map lifecycle is still fully
    -- evaluated).
    OpeningLifecycle.seedPostOpeningHouseState(game)

    local expectedTransitionScriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "New Bark must declare an on_transition lifecycle script"
    )
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "generated New Bark rules must have a script for scene value 1"
    )

    -- New Bark's on_transition lifecycle is allowed to run before ordinary
    -- frame-rule ownership.
    game:advanceUntil("New Bark's on_transition lifecycle starts", function()
      return #recordsNamed(game, "script.started") > 0
    end, 30)
    local starts = recordsNamed(game, "script.started")
    Assert.equal(
      starts[1].payload.scriptId,
      expectedTransitionScriptId,
      "on_transition must start before the frame rule"
    )

    -- Only once that lifecycle ownership settles does the frame rule for
    -- house scene value 1 start the friend/Marill scene, exactly once.
    game:advanceUntil("the friend/Marill scene starts", function(snapshot)
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedSceneScriptId then
          return true
        end
      end
      return false
    end, 120)
    local sceneStarts = {}
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStarts[#sceneStarts + 1] = record
      end
    end
    Assert.equal(#sceneStarts, 1, "the friend/Marill scene must start exactly once")

    local transitionEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedTransitionScriptId then
        transitionEnds[#transitionEnds + 1] = record
      end
    end
    Assert.equal(#transitionEnds, 1, "the on_transition lifecycle must end before the frame rule owns the field")

    -- Advance until its source state mutation/hide-show sequence settles:
    -- the source scene sets the house scene variable to 2 and hides both
    -- the friend and Marill.
    local world = game.runtime.scripts.worldState
    game:advanceUntil("the friend/Marill scene settles", function(snapshot)
      return world:getVar(VAR_SCENE_PLAYERS_HOUSE_1F) == 2
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_FRIEND)
        and world:isFlagSet(FLAG_HIDE_NEW_BARK_MARILL)
        and not snapshot.fieldLocked
    end, 400)

    -- The scene variable no longer satisfies the same one-shot trigger
    -- (value 1), so it must not restart.
    for _ = 1, 30 do
      game:step()
    end
    local sceneStartsAfter = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsAfter = sceneStartsAfter + 1
      end
    end
    Assert.equal(sceneStartsAfter, 1, "the settled friend/Marill scene must not restart")
  end, { recordingScriptHosts = true })
end

function T.tests.lifecycle_predicate_survives_a_faulted_foreground_owner()
  withGame(TOWN, function(game)
    -- Same documented precondition as the New Bark scenario above: this
    -- test's purpose is lifecycle arbitration under New Bark's own
    -- on_transition + on_frame_eq handoff, not the House 1F Mom scene.
    OpeningLifecycle.seedPostOpeningHouseState(game)

    local expectedTransitionScriptId = assert(
      OpeningLifecycle.lifecycleScriptId(game.runtime, "on_transition"),
      "New Bark must declare an on_transition lifecycle script"
    )
    local expectedSceneScriptId = assert(
      OpeningLifecycle.frameRuleScriptId(game.runtime, VAR_SCENE_PLAYERS_HOUSE_1F, 1),
      "generated New Bark rules must have a script for scene value 1"
    )

    -- The on_frame_eq predicate for house scene value 1 is already true the
    -- entire time: it must not start concurrently with the on_transition
    -- lifecycle, and it must not be treated as lost once ownership frees up.
    -- New Bark's real on_transition script has no unsupported branch left to
    -- reach on a fresh world (every opcode it exercises is implemented and
    -- none of them block), so it now runs to completion within the single
    -- tick it starts on, leaving no window to observe it mid-flight. This
    -- scenario widens that window with the scheduler's own per-tick node
    -- budget (a real diagnostic control, `Scheduler:setMaxNodes`, documented
    -- for tests), then ends the still-running instance deterministically at
    -- the scheduler's error boundary: a real production `cancelInstance`
    -- call, the same termination path a faulted task escalates through,
    -- produces the identical `script.ended` (completed=false, reason set)
    -- surface this contract requires.
    game.runtime.scripts.scheduler:setMaxNodes(1)
    local transitionInstanceId
    game:advanceUntil("New Bark's on_transition lifecycle starts", function()
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedTransitionScriptId then
          transitionInstanceId = record.payload.instanceId
          return true
        end
      end
      return false
    end, 30)
    game.runtime.scripts.scheduler:cancelInstance(assert(transitionInstanceId), "acceptance-injected termination")

    game:advanceUntil("New Bark's on_transition lifecycle ends", function()
      for _, record in ipairs(recordsNamed(game, "script.ended")) do
        if record.payload.scriptId == expectedTransitionScriptId then
          return true
        end
      end
      return false
    end, 30)

    local transitionEnds = {}
    for _, record in ipairs(recordsNamed(game, "script.ended")) do
      if record.payload.scriptId == expectedTransitionScriptId then
        transitionEnds[#transitionEnds + 1] = record
      end
    end
    Assert.equal(#transitionEnds, 1, "the on_transition lifecycle must surface exactly one end record")
    Assert.isFalse(
      transitionEnds[1].payload.completed,
      "the faulted lifecycle must not be reported as successful completion"
    )
    Assert.notNil(transitionEnds[1].payload.reason, "the fault identity must be observable")

    local sceneStartsWhileTransitionOwnedField = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStartsWhileTransitionOwnedField = sceneStartsWhileTransitionOwnedField + 1
      end
    end
    Assert.equal(
      sceneStartsWhileTransitionOwnedField,
      0,
      "the frame rule must not start while the on_transition lifecycle still owns the field"
    )

    -- The frame predicate remained true throughout and must become eligible
    -- again now that ownership is free; it was not permanently lost because
    -- it was observed while blocked.
    game:advanceUntil("the frame rule starts after the faulted lifecycle releases ownership", function()
      for _, record in ipairs(recordsNamed(game, "script.started")) do
        if record.payload.scriptId == expectedSceneScriptId then
          return true
        end
      end
      return false
    end, 60)
    local sceneStarts = 0
    for _, record in ipairs(recordsNamed(game, "script.started")) do
      if record.payload.scriptId == expectedSceneScriptId then
        sceneStarts = sceneStarts + 1
      end
    end
    Assert.equal(sceneStarts, 1, "the frame rule must start exactly once after ownership frees up")
  end, { recordingScriptHosts = true })
end

function T.tests.mom_source_flags_gate_early_start_menu_state()
  withGame(TOWN, function(game)
    local world = game.runtime.scripts.worldState

    -- Before Mom grants the flags: Bag stays inhibited entirely (absent
    -- from the menu), Trainer Card/Save stay present but disabled (through
    -- the fully composed application host), and Options stays source-locked
    -- (through the pure source policy directly, since Options has no
    -- implemented destination application in this port).
    local before = openMenu(game)
    Assert.isNil(actionById(before, "vanilla.bag"), "Bag must stay inhibited before Mom grants it")
    Assert.isFalse(actionById(before, "vanilla.trainer_card").enabled, "Trainer Card must stay locked before Mom")
    Assert.isFalse(actionById(before, "vanilla.save").enabled, "Save must stay locked before Mom")
    Assert.isFalse(
      sourcePolicyActionById(world, "vanilla.options").sourceEnabled,
      "Options must stay source-locked before Mom"
    )
    closeMenu(game)

    enterHouse(game)
    OpeningLifecycle.completeOpeningHouseScene(game)

    -- After Mom grants the flags: the same live world flags now
    -- enable/present the implemented actions, through the existing
    -- production Start Menu policy composition alone.
    local after = openMenu(game)
    Assert.notNil(actionById(after, "vanilla.bag"), "Bag must become present once Mom grants it")
    Assert.isTrue(actionById(after, "vanilla.trainer_card").enabled, "Trainer Card must unlock after Mom")
    Assert.isTrue(actionById(after, "vanilla.save").enabled, "Save must unlock after Mom")
    Assert.isTrue(
      sourcePolicyActionById(world, "vanilla.options").sourceEnabled,
      "Options must unlock at the source policy after Mom"
    )
    closeMenu(game)
  end, { recordingScriptHosts = true })
end

return T
