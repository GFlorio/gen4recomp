-- TrainerCardController contract tests: the close-input-only card
-- controller. It owns no Start Menu internals: a cancel edge records exactly
-- one { kind = "close" } result and requests the card's cancel effect once;
-- every foreign input (directions/confirm/menu/pointers) changes nothing; the
-- status carries the full model projection (the three authoritative
-- profile fields and the explicit nil optional fields) so the renderer can
-- choose the audited blank presentation; dispose is idempotent and discards a
-- pending result; construction requires the model and the audio facade.

local Assert = require("tests.support.Assert")
local TrainerCardModel = require("libs.engine.src.TrainerCardModel")
local TrainerCardController = require("libs.engine.src.TrainerCardController")

local T = {
  tests = {},
}

local function throws(fn)
  return Assert.throws(fn)
end

local function recordingAudio()
  local audio = { requests = {} }
  function audio:play(requestId)
    self.requests[#self.requests + 1] = requestId
  end
  return audio
end

local function demoProfile()
  return {
    profile = { name = "GOLD", gender = 0, trainerId = 0 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
end

local function fixture(profile)
  local audio = recordingAudio()
  local controller = TrainerCardController.new({
    model = TrainerCardModel.new(profile or demoProfile()),
    audio = audio,
  })
  return controller, audio
end

function T.tests.construction_requires_the_model_and_audio_facade()
  local audio = recordingAudio()
  throws(function()
    TrainerCardController.new({ audio = audio })
  end)
  throws(function()
    TrainerCardController.new({ model = TrainerCardModel.new(demoProfile()) })
  end)
end

function T.tests.construction_requests_no_sound()
  local _, audio = fixture()
  Assert.deepEqual(audio.requests, {}, "the card opens silently (the menu select already played)")
end

function T.tests.status_carries_the_full_model_projection()
  local controller = fixture()
  local status = controller:status()
  Assert.equal(status.open, true)
  Assert.equal(status.name, "GOLD")
  Assert.equal(status.gender, 0)
  Assert.equal(status.trainerId, 0)
  Assert.equal(status.money, nil)
  Assert.equal(status.playTime, nil)
  Assert.equal(status.badges, nil)
  Assert.equal(status.pokedexOwned, nil)
  Assert.equal(status.stars, nil)
  Assert.equal(status.signature, nil)
end

function T.tests.status_passes_boundary_profile_values_through()
  local controller = fixture({
    profile = { name = "ABCDEFG", gender = 1, trainerId = 65535 },
    options = { textFrame = 0, textSpeed = "mid" },
  })
  local status = controller:status()
  Assert.equal(status.name, "ABCDEFG")
  Assert.equal(status.gender, 1)
  Assert.equal(status.trainerId, 65535)
end

function T.tests.a_cancel_edge_records_one_close_result_and_one_cancel_sound()
  local controller, audio = fixture()
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(audio.requests, { "start_menu.cancel" }, "closing the card requests the cancel effect once")
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
  Assert.equal(controller:takeResult(), nil, "the close result is delivered exactly once")
end

function T.tests.foreign_input_changes_nothing()
  local controller, audio = fixture()
  controller:updateFixed({
    { type = "navigate", direction = "south" },
    { type = "confirm" },
    { type = "menu" },
    { type = "pointer_down", pointerId = "touch:1", x = 192, y = 19 },
    { type = "pointer_up", pointerId = "touch:1", x = 192, y = 19 },
  })
  Assert.equal(controller:takeResult(), nil, "foreign input must never close or launch the card")
  Assert.deepEqual(audio.requests, {}, "foreign input must not request sounds")
  local status = controller:status()
  Assert.equal(status.open, true, "the card stays open under foreign input")
  Assert.equal(status.trainerId, 0, "the presentation is unchanged")
end

function T.tests.the_menu_edge_does_not_close_the_card()
  local controller, audio = fixture()
  controller:updateFixed({ { type = "menu" } })
  Assert.equal(controller:takeResult(), nil, "the menu key must not tear down a child application")
  Assert.equal(controller:status().open, true)
  Assert.deepEqual(audio.requests, {})
end

function T.tests.dispose_is_idempotent_and_discards_a_pending_result()
  local controller = fixture()
  controller:updateFixed({ { type = "cancel" } })
  controller:dispose()
  controller:dispose()
  Assert.equal(controller:takeResult(), nil, "dispose discards the pending close result")
  Assert.equal(controller:status().open, false)
end

function T.tests.update_fixed_after_close_is_a_noop()
  local controller, audio = fixture()
  controller:updateFixed({ { type = "cancel" } })
  controller:updateFixed({ { type = "cancel" } })
  Assert.deepEqual(controller:takeResult(), { kind = "close" }, "only the first cancel edge produces the close result")
  Assert.equal(controller:takeResult(), nil, "the second cancel edge produces nothing")
  Assert.equal(#audio.requests, 1, "only the first close requests the cancel effect")
end

return T
