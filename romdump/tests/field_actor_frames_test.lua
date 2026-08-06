-- Tests frame collection independently of ROM I/O: ordinary resources follow
-- their timelines, while a singleton texture/palette resource remains static
-- even when its shared descriptor carries unusable walking slots.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local Fixture = require("tests.support.FieldActorFixture")
local FieldActorFrames = require("romdump.src.digest.FieldActorFrames")
local FieldActorTimeline = require("romdump.src.digest.FieldActorTimeline")

local T = {}

local RANGES = {
  { startFrame = 0, endFrame = 3, endMode = 0 },
  { startFrame = 4, endFrame = 7, endMode = 0 },
  { startFrame = 8, endFrame = 11, endMode = 0 },
  { startFrame = 12, endFrame = 15, endMode = 0 },
}

local function timeline()
  return assert(FieldActorTimeline.decode(Fixture.timeline({
    { threshold = 0, textureSlot = 0 },
    { threshold = 2, textureSlot = 1 },
  })))
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
end

function T.collects_reachable_timeline_slots()
  local result = FieldActorFrames.collect(timeline(), RANGES, 2, 1)
  Assert.equal(result.mode, "timeline")
  Assert.deepEqual(result.frames, {
    { textureSlot = 0, paletteSlot = 0 },
    { textureSlot = 1, paletteSlot = 0 },
  })
  Assert.deepEqual(result.perRange[1], {
    { frameIndex = 1, ticks = 2 },
    { frameIndex = 2, ticks = 2 },
  })
end

function T.singleton_resource_ignores_unusable_walking_slots()
  local result = FieldActorFrames.collect(timeline(), RANGES, 1, 1)
  Assert.equal(result.mode, "static")
  Assert.deepEqual(result.frames, { { textureSlot = 0, paletteSlot = 0 } })
  Assert.deepEqual(result.perRange[1], { { frameIndex = 1, ticks = 4 } })
end

function T.multi_texture_resource_still_rejects_a_missing_slot()
  throwsCode("FIELD_ACTOR_TEXTURE_SLOT_MISSING", function()
    FieldActorFrames.collect(timeline(), RANGES, 1, 2)
  end)
end

return T
