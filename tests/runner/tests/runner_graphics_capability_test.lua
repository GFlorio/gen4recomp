-- The graphics capability is established by a preflight that really creates and
-- releases one of every resource class the graphics suites depend on. Two
-- outcomes are legitimate: no graphics module at all (the capability is simply
-- absent) and a working host (the capability is available). A host that offers
-- the module but cannot produce a resource is an infrastructure failure and must
-- be loud, never a silent downgrade to "skip everything".

local Assert = require("tests.support.Assert")
local Capabilities = require("tests.runner.Capabilities")

local T = {}

-- A `love.graphics`/`love.image`-shaped double. Every constructor records the
-- object it handed out so the preflight's release behavior is observable;
-- `failing` names the constructor that raises, standing in for a host whose
-- context creation fails partway through.
local function fakeHost(failing)
  local host = { created = {} }

  local function construct(kind)
    return function()
      if failing == kind then
        error("fake host cannot create a " .. kind, 0)
      end
      local object = { kind = kind, released = 0 }
      function object:release()
        self.released = self.released + 1
      end
      host.created[#host.created + 1] = object
      return object
    end
  end

  host.graphics = {
    newShader = construct("newShader"),
    newCanvas = construct("newCanvas"),
    newMesh = construct("newMesh"),
    newImage = construct("newImage"),
  }
  host.image = { newImageData = construct("newImageData") }
  return host
end

local function detect(host)
  return Capabilities.detect({
    versions = {},
    env = {},
    graphics = host and host.graphics or false,
    image = host and host.image or false,
  })
end

local function kinds(host)
  local seen = {}
  for _, object in ipairs(host.created) do
    seen[object.kind] = (seen[object.kind] or 0) + 1
  end
  return seen
end

function T.a_working_graphics_host_offers_the_capability()
  local capabilities = detect(fakeHost(nil))

  Assert.isTrue(capabilities.graphics, "a host that creates resources must offer 'graphics'")
end

function T.the_preflight_exercises_shader_canvas_mesh_and_image()
  local host = fakeHost(nil)
  detect(host)

  local seen = kinds(host)
  for _, kind in ipairs({ "newShader", "newCanvas", "newMesh", "newImage" }) do
    Assert.isTrue((seen[kind] or 0) > 0, "the preflight never created a resource through " .. kind)
  end
end

function T.the_preflight_releases_every_resource_it_created()
  local host = fakeHost(nil)
  detect(host)

  Assert.isTrue(#host.created > 0, "the preflight created nothing")
  for _, object in ipairs(host.created) do
    Assert.equal(object.released, 1, object.kind .. " was released " .. object.released .. " times, expected once")
  end
end

function T.no_graphics_module_is_an_absent_capability_not_a_failure()
  local capabilities = detect(nil)

  Assert.isNil(capabilities.graphics, "a host without a graphics module must not claim 'graphics'")
end

function T.a_broken_graphics_host_fails_loudly()
  local host = fakeHost("newShader")

  local err = Assert.throws(function()
    detect(host)
  end)

  Assert.isTrue(
    tostring(err):lower():find("graphic", 1, true) ~= nil,
    "the failure must name the graphics preflight, got: " .. tostring(err)
  )
end

function T.a_failed_preflight_releases_what_it_already_acquired()
  local host = fakeHost("newMesh")

  Assert.throws(function()
    detect(host)
  end)

  Assert.isTrue(#host.created > 0, "nothing was acquired before the injected failure")
  for _, object in ipairs(host.created) do
    Assert.equal(object.released, 1, object.kind .. " leaked when the preflight failed")
  end
end

return T
