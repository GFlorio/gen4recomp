-- Ownership contract of the real-dump suite adapter. It owns one RomFs per
-- ready version, including partial-acquisition cleanup.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

-- A RomFs stand-in that records how often it was closed.
local function fakeRomFs(versionId)
  return {
    versionId = versionId,
    closed = 0,
    close = function(self)
      self.closed = self.closed + 1
    end,
  }
end

local function opener(failOn)
  local opened = {}
  local open = function(versionId)
    if versionId == failOn then
      return nil, "dump unreadable"
    end
    local romFs = fakeRomFs(versionId)
    opened[#opened + 1] = romFs
    return romFs
  end
  return open, opened
end

local function build(options)
  local open, opened = opener(options.failOn)
  local suite = RomSuite.build({
    tests = options.tests,
    readyVersions = options.readyVersions or { "heartgold", "soulsilver" },
    open = open,
  })
  return suite, opened
end

function T.every_fact_runs_once_per_ready_version()
  local calls = {}
  local suite = build({
    tests = {
      checks_a_fact = function(romFs, versionId)
        calls[#calls + 1] = tostring(romFs.versionId) .. "/" .. tostring(versionId)
      end,
    },
  })

  Assert.equal(suite.metadata.capabilities[1], "rom_dump")
  Assert.deepEqual(suite.metadata.capabilities, { "rom_dump" })

  local context = {}
  suite.beforeAll(context)
  suite.tests.checks_a_fact(context)
  suite.afterAll(context)

  Assert.deepEqual(calls, { "heartgold/heartgold", "soulsilver/soulsilver" })
end

function T.a_failing_fact_names_the_version()
  local suite = build({
    tests = {
      fails_on_the_second_version = function(_, versionId)
        Assert.isTrue(versionId ~= "soulsilver", "target fact missing")
      end,
    },
  })

  local context = {}
  suite.beforeAll(context)
  local ok, err = pcall(suite.tests.fails_on_the_second_version, context)
  suite.afterAll(context)

  Assert.isFalse(ok, "the legacy failure must propagate")
  Assert.isTrue(tostring(err):find("soulsilver", 1, true) ~= nil, "the failure names the version: " .. tostring(err))
end

function T.cleanup_closes_every_handle_exactly_once_and_repeats_safely()
  local suite, opened = build({ tests = {} })

  local context = {}
  suite.beforeAll(context)
  suite.afterAll(context)
  suite.afterAll(context)

  Assert.equal(#opened, 2)
  for _, romFs in ipairs(opened) do
    Assert.equal(romFs.closed, 1, "each RomFs is closed exactly once")
  end
end

function T.a_failed_acquisition_releases_the_handles_already_open()
  local suite, opened = build({ tests = {}, failOn = "soulsilver" })

  local context = {}
  local ok, err = pcall(suite.beforeAll, context)

  Assert.isFalse(ok, "an unopenable dump is a setup failure")
  Assert.isTrue(tostring(err):find("soulsilver", 1, true) ~= nil, "the failure names the version: " .. tostring(err))
  Assert.equal(#opened, 1)
  Assert.equal(opened[1].closed, 1, "the handle acquired before the failure is released")

  suite.afterAll(context)
  Assert.equal(opened[1].closed, 1, "cleanup after a failed setup must not double-close")
end

function T.cleanup_tolerates_a_setup_that_never_ran()
  local suite, opened = build({ tests = {} })

  suite.afterAll({})

  Assert.equal(#opened, 0, "nothing was acquired, so nothing is released")
end

return { tests = T }
