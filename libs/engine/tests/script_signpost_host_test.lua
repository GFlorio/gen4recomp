-- ScriptSignpostHost tests: the host bridges the script runtime's signpost
-- operations and the field signpost controller. Message resolution goes
-- through the injected public message-resolution operation (never an
-- underscored helper or duplicated substitution semantics); configuration
-- and window/printer requests pass through presentation-neutral; the host
-- never writes world variables; modal ownership is the controller's alone;
-- and close() releases that ownership exactly once through the controller's
-- explicit cleanup.

local Assert = require("tests.support.Assert")
local ScriptSignpostHost = require("libs.engine.src.script.ScriptSignpostHost")

local T = {}

-- A controller fake faithful to the real surface the host touches: the bare
-- command assignment, the same-update SHOW/HIDE completion, the explicit
-- cleanup, printer requests, the semantic idle query, and modal ownership on
-- the presented window.
local function fakeController()
  local controller = {
    command = "nop",
    active = false,
    appearance = nil,
    calls = {},
    instant = nil,
    typed = nil,
    finishes = 0,
    updates = 0,
    releases = 0,
  }
  function controller:setCommand(command)
    self.calls[#self.calls + 1] = "setCommand"
    self.command = command
  end
  function controller:updateFixed()
    self.calls[#self.calls + 1] = "updateFixed"
    self.updates = self.updates + 1
    if self.command == "show" then
      self.active = true
      self.command = "nop"
    elseif self.command == "hide" then
      self:hideImmediately()
    end
  end
  function controller:hideImmediately()
    self.calls[#self.calls + 1] = "hideImmediately"
    if self.active then
      self.releases = self.releases + 1
    end
    self.active = false
    self.print = nil
    self.command = "nop"
    self.styleId = self.defaultStyleId or "hgss.signpost"
  end
  function controller:printInstant(message)
    self.calls[#self.calls + 1] = "printInstant"
    self.instant = message
    self.printDone = true
  end
  function controller:printTyped(message)
    self.calls[#self.calls + 1] = "printTyped"
    self.typed = message
  end
  function controller:finishPrint()
    self.calls[#self.calls + 1] = "finishPrint"
    self.finishes = self.finishes + 1
    self.printDone = true
  end
  function controller:setSourceAppearance(appearance)
    self.calls[#self.calls + 1] = "setSourceAppearance"
    self.appearance = appearance and { game = appearance.game, type = appearance.type, map = appearance.map } or nil
  end
  function controller:setStyleId(styleId)
    self.calls[#self.calls + 1] = "setStyleId"
    self.styleId = styleId
  end
  function controller:isModal()
    return self.active
  end
  function controller:isCommandIdle()
    return self.command == "nop"
  end
  function controller:isPrintDone()
    return self.printDone == true
  end
  function controller:status()
    return { active = self.active, command = self.command, printDone = false }
  end
  return controller
end

local function host(opts)
  opts = opts or {}
  local controller = opts.controller or fakeController()
  local resolver = opts.resolver
  if resolver == nil then
    resolver = function()
      return { text = "resolved", tokens = {} }
    end
  end
  local h = ScriptSignpostHost.new({
    controller = controller,
    resolveMessage = resolver,
  })
  return h, controller, resolver
end

function T.construction_requires_the_controller_and_resolution_operation()
  local ok, err = pcall(ScriptSignpostHost.new, { controller = fakeController() })
  Assert.isFalse(ok, "the host requires the injected message-resolution operation: " .. tostring(err))
  local ok2, err2 = pcall(ScriptSignpostHost.new, { resolveMessage = function() end })
  Assert.isFalse(ok2, "the host requires the signpost controller: " .. tostring(err2))
  local h = ScriptSignpostHost.new({
    controller = fakeController(),
    resolveMessage = function() end,
  })
  Assert.isTrue(type(h) == "table", "controller plus resolution operation constructs the host")
end

-- The opcode-55 path: read and expand the message through the injected
-- resolution operation, then print it instantly in the signpost window.
function T.print_instant_resolves_the_message_then_prints_instantly()
  local controller = fakeController()
  local resolved = { text = "resolved", tokens = {} }
  local seen = {}
  local h, _, _ = host({
    controller = controller,
    resolver = function(message, bindings, textArgs)
      seen[#seen + 1] = { message = message, bindings = bindings, textArgs = textArgs }
      return resolved
    end,
  })
  local bindings = { [0] = { text = "integer", value = { value = "var", id = "VAR_X" } } }
  local textArgs = { [1] = { text = "player_name" } }
  h:printInstant("msg.hgss.0542.00000", bindings, textArgs)
  Assert.equal(#seen, 1, "the message resolves exactly once")
  Assert.equal(seen[1].message, "msg.hgss.0542.00000")
  Assert.equal(seen[1].bindings, bindings, "the node's bindings pass through unchanged")
  Assert.equal(seen[1].textArgs, textArgs, "the instance's text arguments pass through unchanged")
  Assert.equal(controller.instant, resolved, "the resolved message prints instantly")
  Assert.isNil(controller.typed, "an instant print never requests a typed print")
end

-- The Trainer Tips path: resolve, then request a typed print. The request is
-- presentation-neutral: the controller receives only the resolved message,
-- never a cadence, colors, or geometry the host would have to choose.
function T.print_typed_resolves_the_message_and_requests_only_the_typed_print()
  local controller = fakeController()
  local resolved = { text = "resolved", tokens = {} }
  local seen = 0
  local h, _, _ = host({
    controller = controller,
    resolver = function()
      seen = seen + 1
      return resolved
    end,
  })
  h:printTyped("msg.hgss.0542.00009", {}, {})
  Assert.equal(seen, 1, "the message resolves exactly once")
  Assert.equal(controller.typed, resolved, "the resolved message goes to the typed printer")
  Assert.isNil(controller.instant, "a typed print never prints instantly")
  Assert.equal(#controller.calls, 1, "the typed request is the only controller operation")
end

-- A resolution failure propagates unchanged and never reaches the controller:
-- a half-configured signpost window or printer is not possible.
function T.resolution_failure_propagates_and_leaves_the_controller_untouched()
  local controller = fakeController()
  local expected = { code = "SCRIPT_INVALID_REFERENCE", message = "boom" }
  local h = ScriptSignpostHost.new({
    controller = controller,
    resolveMessage = function()
      error(expected, 0)
    end,
  })
  local err = Assert.throws(function()
    h:printTyped("msg.hgss.9999.00000", {}, {})
  end)
  Assert.equal(err, expected, "the resolution failure propagates unchanged")
  Assert.isNil(controller.typed, "a failed resolve never reaches the printer")
  Assert.equal(#controller.calls, 0, "a failed resolve touches no controller operation")
end

-- The source appearance is presentation data the host stores without
-- interpreting: the raw type/map pass through untouched, never resolved to
-- geometry.
function T.set_source_appearance_forwards_the_configuration_without_resolving_geometry()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  local appearance = { game = "hgss", type = 3, map = 42 }
  h:setSourceAppearance(appearance)
  Assert.deepEqual(controller.appearance, appearance, "the raw source appearance passes through unchanged")
  h:setSourceAppearance(nil)
  Assert.isNil(controller.appearance, "nil clears the stored appearance")
end

function T.set_command_forwards_the_window_request()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  h:setCommand("wipe_in")
  Assert.equal(controller.command, "wipe_in", "the window request reaches the controller command")
end

-- The high-level sign path routes a script-requested style id through the
-- host into the controller's presentation routing.
function T.set_style_id_forwards_the_requested_style()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  h:setStyleId("mod.route_sign")
  Assert.equal(controller.styleId, "mod.route_sign", "the requested style id reaches the controller")
end

-- Style routing is the high-level semantic presentation: routing a style
-- clears any stored source appearance, so an imported signpost's type/map
-- data can never leak into a later high-level sign.
function T.set_style_id_clears_a_stored_source_appearance()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  h:setSourceAppearance({ game = "hgss", type = 0, map = 11 })
  h:setStyleId("mod.route_sign")
  Assert.isNil(controller.appearance, "style routing must clear the stored source appearance")
end

-- The close teardown returns the routed style to the default with the rest
-- of the presentation, so a high-level flow never leaks its style into a
-- later flow.
function T.close_resets_the_routed_style_to_the_default()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  h:setStyleId("mod.route_sign")
  h:setCommand("show")
  h:advance()
  Assert.isTrue(h:isModal())
  h:close()
  Assert.isFalse(h:isModal())
  Assert.equal(controller.styleId, "hgss.signpost", "close must restore the default style id")
end

-- The scheduler calls advance exactly once per tick; it must touch only the
-- controller's fixed-tick step, never resolve anything or request a print.
function T.advance_steps_the_controller_once_per_scheduler_tick()
  local controller = fakeController()
  local resolved = 0
  local h, _, _ = host({
    controller = controller,
    resolver = function()
      resolved = resolved + 1
      return {}
    end,
  })
  h:advance()
  h:advance()
  Assert.equal(controller.updates, 2, "one controller step per advance call")
  Assert.deepEqual(controller.calls, { "updateFixed", "updateFixed" }, "advance performs no other operation")
  Assert.equal(resolved, 0, "advance never resolves a message")
end

-- Modal ownership is the controller's alone: the host surfaces the
-- controller's state and keeps no second boolean of its own.
function T.is_modal_surfaces_the_controller_ownership()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  Assert.isFalse(h:isModal())
  h:setCommand("show")
  h:advance()
  Assert.isTrue(h:isModal(), "the host follows the controller's presented window")
  h:close()
  Assert.isFalse(h:isModal(), "the host has no modal state of its own to keep")
end

function T.status_forwards_the_controller_snapshot()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  controller.active = true
  Assert.deepEqual(h:status(), { active = true, command = "nop", printDone = false })
end

-- The instant-fill request passes through to the controller verbatim: the
-- host resolves no message and performs no other operation.
function T.finish_print_forwards_the_fill_request()
  local controller = fakeController()
  local resolved = 0
  local h, _, _ = host({
    controller = controller,
    resolver = function()
      resolved = resolved + 1
      return {}
    end,
  })
  h:finishPrint()
  Assert.equal(controller.finishes, 1, "the fill request reaches the controller exactly once")
  Assert.deepEqual(controller.calls, { "finishPrint" }, "finishPrint performs no other operation")
  Assert.equal(resolved, 0, "finishPrint never resolves a message")
end

-- The semantic idle query comes straight from the controller; the host keeps
-- no idle state of its own.
function T.is_command_idle_forwards_the_controller_query()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  Assert.isTrue(h:isCommandIdle(), "the idle query follows the controller's command")
  controller:setCommand("wipe_in")
  Assert.isFalse(h:isCommandIdle(), "a busy command is not idle through the host")
end

-- The semantic print query comes straight from the controller; the host
-- keeps no print state of its own.
function T.is_print_done_forwards_the_controller_query()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  Assert.isFalse(h:isPrintDone(), "the print query follows the controller's printer")
  controller:printInstant({})
  Assert.isTrue(h:isPrintDone(), "a completed controller print is done through the host")
end

-- The close teardown is the controller's explicit cleanup: no scheduled
-- command, no fixed-tick step from the host — the window, printer, command,
-- and routed style are released on the call, exactly once.
function T.close_releases_modal_ownership_exactly_once()
  local controller = fakeController()
  local h, _, _ = host({ controller = controller })
  h:setCommand("show")
  h:advance()
  h:printInstant({ text = "resolved", tokens = {} }, {}, {})
  Assert.isTrue(h:isModal())
  h:close()
  Assert.isFalse(h:isModal(), "close releases modal ownership")
  Assert.equal(controller.command, "nop", "close returns the command to nop")
  Assert.equal(controller.releases, 1, "modal ownership is released exactly once")
  Assert.isNil(controller.print, "close clears the printer")
  Assert.deepEqual(
    controller.calls,
    { "setCommand", "updateFixed", "printInstant", "hideImmediately" },
    "close performs the explicit cleanup, never a fixed-tick step"
  )
  h:close()
  Assert.isFalse(h:isModal(), "a second close has no further effect")
  Assert.equal(controller.releases, 1, "a second close does not release again")
end

-- The host's only external interactions are the injected resolution
-- operation and the controller: no world-variable write path exists on a
-- print request (variable writes stay authoritative in Runtime.writeRef via
-- task results).
function T.print_paths_touch_only_the_resolver_and_the_controller()
  local controller = fakeController()
  local seen = 0
  local h, _, _ = host({
    controller = controller,
    resolver = function()
      seen = seen + 1
      return { text = "resolved", tokens = {} }
    end,
  })
  h:printInstant("msg.hgss.0542.00000", {}, {})
  Assert.equal(seen, 1)
  Assert.deepEqual(controller.calls, { "printInstant" }, "the print path performs no other interaction")
end

return { tests = T }
