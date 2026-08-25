-- Contract tests for live test progress: every tenth passing test emits one
-- dot, non-passing results emit colored markers, and long streams wrap.

local Assert = require("tests.support.Assert")
local Progress = require("tests.runner.Progress")
local FakeCorpus = require("tests.runner.tests.support.FakeCorpus")
local TestRunner = require("tests.runner.TestRunner")

local T = {}

local function writer()
  local output = {}
  return output, function(text)
    output[#output + 1] = text
  end
end

function T.emits_one_global_stream_with_colored_nonpassing_markers()
  local output, write = writer()
  local progress = Progress.new(write)

  for _ = 1, 9 do
    progress:record({ layer = "unit", status = "pass" })
  end
  progress:record({ layer = "unit", status = "pass" })
  progress:record({ layer = "unit", status = "skip" })
  progress:record({ layer = "unit", status = "fail" })
  progress:finish()

  Assert.deepEqual(output, { ".", "\27[33mS\27[0m", "\27[31mF\27[0m", "\n" })
end

function T.wraps_after_120_progress_symbols()
  local output, write = writer()
  local progress = Progress.new(write)

  for _ = 1, 1200 do
    progress:record({ layer = "unit", status = "pass" })
  end
  progress:finish()

  local text = table.concat(output)
  local newlineCount = select(2, text:gsub("\n", ""))
  Assert.equal(newlineCount, 1)
  Assert.equal(#text, 121)
end

function T.execution_forwards_every_result_to_progress()
  local corpus = FakeCorpus.new({
    ["fake/unit/results_test.lua"] = {
      tests = {
        ["passes"] = function() end,
        ["skips"] = function(context)
          context:skip("not today")
        end,
        ["fails"] = function()
          error("deliberate", 0)
        end,
      },
    },
  })
  local seen = {}
  local run = TestRunner.run({
    roots = { corpus:root("fake/unit", "unit") },
    fs = corpus.fs,
    load = corpus.load,
    onResult = function(result)
      seen[#seen + 1] = result.status
    end,
  })

  table.sort(seen)
  Assert.deepEqual(seen, { "fail", "pass", "skip" })
  Assert.equal(run.passed, 1)
  Assert.equal(run.skipped, 1)
  Assert.equal(run.failed, 1)
end

return { tests = T }
