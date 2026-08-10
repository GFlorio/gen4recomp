-- `--list` must survive a module that cannot be loaded. Execution already
-- reports such a module as one failed `<load>` result; listing used to raise
-- instead, so one broken suite replaced the whole corpus listing with a
-- traceback.

local Assert = require("tests.support.Assert")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

function T.listing_reports_a_broken_module_instead_of_raising()
  local corpus = FakeCorpus.new({
    ["fake/list/alpha_test.lua"] = { a = function() end },
    ["fake/list/broken_test.lua"] = FakeCorpus.LOAD_ERROR,
  })

  local listing = TestRunner.list({ roots = { corpus:root("fake/list", "unit") }, fs = corpus.fs, load = corpus.load })

  Assert.equal(#listing, 2, "a broken module is still listed")
  Assert.equal(listing[1].module, "fake.list.alpha_test")
  Assert.isNil(listing[1].error)
  Assert.equal(listing[2].module, "fake.list.broken_test")
  Assert.isTrue(
    tostring(listing[2].error):find("fake load failure", 1, true) ~= nil,
    "the broken suite carries its load error, got: " .. tostring(listing[2].error)
  )
  Assert.deepEqual(listing[2].tests, {})
end

return T
