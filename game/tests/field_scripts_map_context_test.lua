-- FieldScripts active-map entry points: onZoneChange and onMapSwap must both
-- leave every map-scoped script collaborator (maps service, script-client
-- bank id, init-controller rules/map id, mapSource) bound to the destination
-- map. Only onMapSwap additionally replaces the player facade, and it must do
-- so before the map-scoped collaborators are rebound.

local Assert = require("tests.support.Assert")
local FieldScripts = require("game.src.game.FieldScripts")

local T = { tests = {} }

-- Builds a fake FieldScripts-shaped self with recording collaborators. `log`
-- accumulates call names in invocation order so ordering can be asserted.
local function fakeSelf()
  local log = {}
  local fake = {
    log = log,
    player = {
      calls = {},
      setPlayer = function(self, player)
        table.insert(log, "player.setPlayer")
        table.insert(self.calls, player)
      end,
    },
    mapsService = {
      calls = {},
      setSourceMap = function(self, sourceMap)
        table.insert(log, "mapsService.setSourceMap")
        table.insert(self.calls, sourceMap)
      end,
    },
    client = {
      calls = {},
      setScriptBankId = function(self, scriptBankId)
        table.insert(log, "client.setScriptBankId")
        table.insert(self.calls, scriptBankId)
      end,
    },
    initController = {
      calls = {},
      setRules = function(self, initScripts, mapId)
        table.insert(log, "initController.setRules")
        table.insert(self.calls, { initScripts = initScripts, mapId = mapId })
      end,
    },
  }
  return fake
end

local function destinationMap()
  return {
    fieldData = {
      mapId = 42,
      scriptBankId = 7,
      initScripts = { { kind = "on_transition", scriptId = 1 } },
    },
  }
end

function T.tests.zone_change_establishes_complete_destination_map_context()
  local fake = fakeSelf()
  local destination = destinationMap()

  FieldScripts.onZoneChange(fake, destination --[[@as RuntimeFieldMap]])

  Assert.equal(#fake.mapsService.calls, 1, "setSourceMap must be called exactly once")
  Assert.equal(fake.mapsService.calls[1], destination)
  Assert.equal(#fake.client.calls, 1, "setScriptBankId must be called exactly once")
  Assert.equal(fake.client.calls[1], destination.fieldData.scriptBankId)
  Assert.equal(#fake.initController.calls, 1, "setRules must be called exactly once")
  Assert.deepEqual(fake.initController.calls[1], {
    initScripts = destination.fieldData.initScripts,
    mapId = destination.fieldData.mapId,
  })
  Assert.equal(fake.mapSource, destination)
  Assert.equal(#fake.player.calls, 0, "onZoneChange must never replace the player facade")
end

function T.tests.map_swap_retains_player_rebind_while_sharing_map_context()
  local fake = fakeSelf()
  local destination = destinationMap()
  local newPlayer = { id = "new-player" }
  ---@cast newPlayer FieldPlayer

  FieldScripts.onMapSwap(fake, newPlayer, destination --[[@as RuntimeFieldMap]])

  Assert.equal(#fake.player.calls, 1, "setPlayer must be called exactly once")
  Assert.equal(fake.player.calls[1], newPlayer)
  Assert.equal(#fake.mapsService.calls, 1, "setSourceMap must be called exactly once")
  Assert.equal(fake.mapsService.calls[1], destination)
  Assert.equal(#fake.client.calls, 1, "setScriptBankId must be called exactly once")
  Assert.equal(fake.client.calls[1], destination.fieldData.scriptBankId)
  Assert.equal(#fake.initController.calls, 1, "setRules must be called exactly once")
  Assert.deepEqual(fake.initController.calls[1], {
    initScripts = destination.fieldData.initScripts,
    mapId = destination.fieldData.mapId,
  })
  Assert.equal(fake.mapSource, destination)

  Assert.equal(fake.log[1], "player.setPlayer", "the player must be rebound before map-scoped collaborators")
  Assert.isTrue(#fake.log >= 2, "map-scoped collaborators must be invoked after the player rebind")
end

return T
