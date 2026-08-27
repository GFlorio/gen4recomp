-- Production-composed interaction on a non-demo outdoor map. The route and
-- event data come from the derived cache; the test only supplies the isolated
-- save root and the render trap through AcceptanceHarness.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "interaction", "script", "bindings" },
  },
  tests = {},
}

local ROUTE_29_ID = 33
local ROUTE_29_TARGET = { fieldX = 626, fieldZ = 389 }

local DIRECTIONS = {
  { direction = "north", fieldX = 0, fieldZ = 1 },
  { direction = "south", fieldX = 0, fieldZ = -1 },
  { direction = "west", fieldX = 1, fieldZ = 0 },
  { direction = "east", fieldX = -1, fieldZ = 0 },
}

local function actorCandidates(game)
  local runtime = game.runtime
  local runtimeActors = runtime.actors
  ---@cast runtimeActors FieldActorManager
  local actors = {}
  for _, actor in ipairs(runtimeActors:actorsOf(ROUTE_29_ID)) do
    actors[actor.objectEventId] = actor
  end
  local candidates = {}
  for _, event in ipairs(runtime.runtimeMap.fieldData.events.objects) do
    if event.scriptId ~= 0 then
      local actor = actors[event.objectEventId]
      if actor ~= nil then
        for _, offset in ipairs(DIRECTIONS) do
          candidates[#candidates + 1] = {
            actor = actor,
            fieldX = actor.fieldX + offset.fieldX,
            fieldZ = actor.fieldZ + offset.fieldZ,
            facing = offset.direction,
          }
        end
      end
    end
  end
  return candidates
end

-- Locate a real reachable Route 29 actor through semantic movement and press
-- Action at it. The assertion is deliberately after the production resolver:
-- a nil target is the old coverage failure, while an attributed unsupported
-- script error after scheduling is a valid later boundary.
function T.tests.non_demo_interaction_resolves_to_a_concrete_target()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game = harness:boot({
      versionId = versionId,
      map = "MAP_NEW_BARK",
      save = "fresh",
    })
    local ok, err = xpcall(function()
      game:moveTo(ROUTE_29_TARGET, ROUTE_29_ID)
      Assert.equal(game:snapshot().mapId, ROUTE_29_ID)
      local candidates = actorCandidates(game)
      Assert.isTrue(#candidates > 0, "Route 29 must expose a bindable object event")

      local interaction
      for _, candidate in ipairs(candidates) do
        local moved = pcall(game.moveTo, game, {
          fieldX = candidate.fieldX,
          fieldZ = candidate.fieldZ,
        })
        if moved then
          game:face(candidate.facing)
          game:pressAction()
          interaction = game:interaction()
          if interaction.actorId == candidate.actor.actorId then
            break
          end
        end
      end

      Assert.notNil(interaction, "a Route 29 actor must be reachable through field input")
      Assert.equal(interaction.kind, "object")
      Assert.notNil(interaction.scriptId, "a non-demo object interaction must resolve through generated bindings")
      Assert.isTrue(interaction.scriptId ~= "SCRIPT_BINDING_MAP_UNKNOWN")
      Assert.equal(game:renderAttempts(), 0, "acceptance must stop before GPU rendering")
    end, debug.traceback)
    game:close()
    if not ok then
      error(err, 0)
    end
  end)
end

return T
