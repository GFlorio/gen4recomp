-- Contract for the ROM/cache pipeline that composes ready-dump discovery,
-- cache preparation, audit, and the non-rendering runtime. The pipeline owns
-- orchestration only; its injected boundaries are the production importer,
-- builder, auditor, and runtime factory.

local Assert = require("tests.support.Assert")
local CachePipeline = require("romdump.src.CachePipeline")

local T = {}

local ORDER = { "heartgold", "soulsilver" }

local function pipeline(overrides)
  local calls = {}
  local options = {
    versionOrder = ORDER,
    isReady = function(versionId)
      return versionId == "heartgold"
    end,
    prepareVersion = function(versionId)
      calls[#calls + 1] = "prepare:" .. versionId
      return { current = true }
    end,
    auditVersion = function(versionId)
      calls[#calls + 1] = "audit:" .. versionId
      return { ok = true }
    end,
    bootRuntime = function(versionId)
      calls[#calls + 1] = "boot:" .. versionId
      return { dispose = function() end }
    end,
    importSource = function(source, root)
      calls[#calls + 1] = "import:" .. source .. ":" .. root
      return { versionId = "heartgold" }
    end,
    createIsolatedRoot = function()
      calls[#calls + 1] = "create-root"
      return "isolated-root"
    end,
    removeIsolatedRoot = function(root)
      calls[#calls + 1] = "remove-root:" .. root
      return true
    end,
  }
  for key, value in pairs(overrides or {}) do
    options[key] = value
  end
  return CachePipeline.new(options), calls
end

-- ROM-01: only known, marker-ready game versions participate in a pipeline
-- run; stray directories can never become an implicit version selection.
function T.rom_01_enumerates_each_ready_supported_version_once()
  local subject = pipeline()
  Assert.deepEqual(subject:readyVersions(), { "heartgold" })
end

-- ROM-02: preparation is per ready version and reports the cache as current
-- only after the builder confirms every required artifact marker.
function T.rom_02_prepares_every_ready_version_from_its_existing_dump()
  local subject, calls = pipeline()
  local report = subject:prepareReady()
  Assert.deepEqual(report, { heartgold = { current = true } })
  Assert.deepEqual(calls, { "prepare:heartgold" })
end

-- ROM-03: a failed build must leave the previous cache usable. The builder is
-- responsible for staged publication; the pipeline must neither continue to
-- audit/boot nor claim a successful preparation after that failure.
function T.rom_03_stops_after_a_staged_build_failure_without_losing_readiness()
  local subject, calls = pipeline({
    prepareVersion = function()
      return nil, "injected staged write failure"
    end,
  })
  local ok = pcall(subject.prepareReady, subject)
  Assert.isFalse(ok, "the build failure must be visible to the caller")
  Assert.deepEqual(calls, {})
end

-- ROM-04: runtime boot receives only the prepared cache identity. It must not
-- request the original source path after preparation has completed.
function T.rom_04_boots_the_prepared_runtime_without_a_source_rom()
  local subject, calls = pipeline()
  local runtime = subject:bootPrepared("heartgold")
  Assert.notNil(runtime)
  Assert.deepEqual(calls, { "boot:heartgold" })
end

-- ROM-05: dump audit is a ready-dump/cache operation, not a source-ROM import.
function T.rom_05_audits_each_ready_dump_without_a_source_rom()
  local subject, calls = pipeline()
  local reports = subject:auditReady()
  Assert.isTrue(reports.heartgold.ok)
  Assert.deepEqual(calls, { "audit:heartgold" })
end

-- ROM-06: an explicitly supplied source is imported, audited, prepared, and
-- booted in one isolated root, which is always removed after the run.
function T.rom_06_runs_the_optional_source_flow_in_an_isolated_root()
  local subject, calls = pipeline()
  local report = subject:runSource("provided.nds")
  Assert.equal(report.versionId, "heartgold")
  Assert.deepEqual(calls, {
    "create-root",
    "import:provided.nds:isolated-root",
    "audit:heartgold",
    "prepare:heartgold",
    "boot:heartgold",
    "remove-root:isolated-root",
  })
end

-- The verification runtime owns cache and save resources rooted in the isolated
-- import directory. That directory cannot be removed while the runtime is live.
function T.source_flow_disposes_the_runtime_before_releasing_its_isolated_root()
  local disposed = false
  local subject = pipeline({
    bootRuntime = function()
      return {
        dispose = function()
          disposed = true
        end,
      }
    end,
    removeIsolatedRoot = function()
      Assert.isTrue(disposed, "source runtime must be disposed before its root is removed")
      return true
    end,
  })

  local report = subject:runSource("provided.nds")
  Assert.equal(report.versionId, "heartgold")
end

-- ROM-07: source validation/import failure is transactional: it cannot
-- publish readiness or invoke later pipeline stages, but it still cleans up
-- the isolated root.
function T.rom_07_invalid_source_never_reaches_a_live_cache_or_runtime()
  local calls
  local subject
  subject, calls = pipeline({
    importSource = function(_, root)
      calls[#calls + 1] = "import-invalid:" .. root
      return nil, "NDS_UNKNOWN_ROM"
    end,
  })
  local ok = pcall(subject.runSource, subject, "wrong.nds")
  Assert.isFalse(ok, "invalid source must fail the pipeline")
  Assert.deepEqual(calls, { "create-root", "import-invalid:isolated-root", "remove-root:isolated-root" })
end

-- The isolated root is an owned filesystem resource. A failed removal must be
-- visible rather than turning a source run into a false success.
function T.failed_isolated_root_removal_fails_the_source_run()
  local subject = pipeline({
    removeIsolatedRoot = function()
      return false, "injected root removal failure"
    end,
  })
  local err = Assert.throws(function()
    subject:runSource("provided.nds")
  end)
  Assert.isTrue(tostring(err):find("injected root removal failure", 1, true) ~= nil)
end

return T
