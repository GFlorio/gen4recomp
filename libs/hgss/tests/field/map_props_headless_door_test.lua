-- MapProps currently learns a door's sound identity and open/close
-- completion only from a live presentation ModelInstance (see MapProps.lua:
-- "field coordinate -> building placement -> ModelInstance -> semantic door
-- animation"). A headless composition supplies no instances, so the same
-- generated door record (identical placements/doorTiles) resolves a door
-- with no sound and no reachable completion, even though the source data is
-- unchanged. These tests build the SAME generated door record into a
-- doorless (headless) MapProps and an instance-backed (presentation)
-- MapProps and prove they must share one semantic duration/sound authority
-- rather than deriving it only from whether a ModelInstance happens to be
-- attached.

local Assert = require("tests.support.Assert")
local MapProps = require("libs.hgss.src.world.MapProps")
local TilePermissions = require("tests.support.TilePermissions")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")

local T = {}

local DOOR_LOCAL_X, DOOR_LOCAL_Z = 4, 14
local DOOR_BEHAVIOR = 105 -- MetatileBehavior.BEHAVIOR.DOOR

local function doorRecordFixture()
  local worldX, worldZ = FieldGrid.tileCenterToWorld(DOOR_LOCAL_X, DOOR_LOCAL_Z)
  local transform = {}
  for i = 1, 16 do
    transform[i] = 0
  end
  transform[13], transform[15] = worldX, worldZ
  local placements = {
    {
      placementIndex = 1,
      modelKey = "field/new_bark/player_house",
      transform = transform,
      doorSoundType = 1,
      doorRoles = { open = { frameCount = 5 } },
    },
  }
  local doorTiles = { { x = DOOR_LOCAL_X, z = DOOR_LOCAL_Z } }
  local runtimeMap = {
    coordinateOrigin = { x = 0, z = 0 },
    collision = TilePermissions.new({
      [DOOR_LOCAL_X .. ":" .. DOOR_LOCAL_Z] = { behavior = DOOR_BEHAVIOR },
    }),
    fieldData = {
      events = {
        warps = { { index = 0, x = DOOR_LOCAL_X, z = DOOR_LOCAL_Z, destinationMapId = 1, destinationWarpId = 0 } },
      },
    },
  }
  return placements, doorTiles, runtimeMap
end

-- A deterministic non-GPU fake standing at the true presentation boundary:
-- it satisfies the ModelInstance contract MapDoor:_play/isFinished reads
-- (definition:animation, play, stop, player:isComplete) without allocating
-- any love.graphics resource.
local function fakeModelInstance()
  return {
    definition = {
      doorSoundType = 1,
      animation = function(_, role)
        return role
      end,
    },
    play = function(_, role)
      return {
        role = role,
        player = {
          frame = 0,
          isComplete = function(self)
            return self.frame >= 5
          end,
        },
      }
    end,
    stop = function() end,
  }
end

function T.headless_and_presentation_doors_share_sound_identity()
  local placements, doorTiles, runtimeMap = doorRecordFixture()
  local headlessProps = MapProps.new({ placements = placements, instances = {}, doorTiles = doorTiles })
  local presentationProps =
    MapProps.new({ placements = placements, instances = { [1] = fakeModelInstance() }, doorTiles = doorTiles })

  local headlessDoor = assert(
    headlessProps:doorAt(runtimeMap, DOOR_LOCAL_X, DOOR_LOCAL_Z),
    "the same generated door record must resolve headlessly"
  )
  local presentationDoor = assert(
    presentationProps:doorAt(runtimeMap, DOOR_LOCAL_X, DOOR_LOCAL_Z),
    "the same generated door record must resolve with presentation attached"
  )

  local headlessSound = headlessDoor:open()
  local presentationSound = presentationDoor:open()
  Assert.equal(
    headlessSound,
    presentationSound,
    "door sound identity must come from generated data, not from whether a ModelInstance is attached"
  )
end

function T.headless_and_presentation_doors_share_completion_timing()
  local placements, doorTiles, runtimeMap = doorRecordFixture()
  local headlessProps = MapProps.new({ placements = placements, instances = {}, doorTiles = doorTiles })
  local presentationProps =
    MapProps.new({ placements = placements, instances = { [1] = fakeModelInstance() }, doorTiles = doorTiles })

  local headlessDoor = assert(headlessProps:doorAt(runtimeMap, DOOR_LOCAL_X, DOOR_LOCAL_Z))
  local presentationDoor = assert(presentationProps:doorAt(runtimeMap, DOOR_LOCAL_X, DOOR_LOCAL_Z))
  headlessDoor:open()
  presentationDoor:open()

  Assert.equal(
    headlessDoor:isFinished(),
    presentationDoor:isFinished(),
    "an unfinished open role must report the same semantic state headlessly and with presentation attached"
  )

  -- Advance each side independently to the same generated duration (5
  -- frames): the headless door on the deterministic engine clock
  -- (MapProps:updateFixed), the presentation attachment's fake ModelInstance
  -- by simulating its own frame advance. The generated duration is the
  -- single semantic authority; headless and presentation must reach
  -- completion at the same frame count without
  -- sharing any mutable state between them.
  for _ = 1, 5 do
    headlessProps:updateFixed()
  end
  presentationDoor.entry.animation.player.frame = 5

  Assert.equal(
    headlessDoor:isFinished(),
    presentationDoor:isFinished(),
    "open-role completion must be decided by one semantic duration authority, not by ModelInstance attachment"
  )
  Assert.isTrue(headlessDoor:isFinished(), "both sides must actually reach completion, not just agree on nil")
end

return { tests = T }
