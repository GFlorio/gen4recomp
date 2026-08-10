-- Shared staging/publication lifecycle for generated cache artifacts. A writer
-- stages every owned file under a disposable staging root (`staging/<version>/
-- <name>/`, mirroring the live cache-relative layout), validates the staged
-- result, and only then publishes it: each owned live root is moved aside, the
-- staged roots are renamed into place, and the stage (with the aside roots
-- inside it) is removed. A failure at any point leaves the previous live artifact
-- untouched: staging never writes to the live tree, and a failed publish rolls
-- every moved root back before re-raising. Paths, validation, and readback stay
-- with the individual cache classes; this module only encodes the common
-- lifecycle. Love-free; all IO goes through the CacheFs backend.

local CacheFs = require("libs.rom.src.CacheFs")

---@class ArtifactPublisher
---@field stage CacheFs
---@field private _cacheFs CacheFs
---@field private _liveRoots string[]
local ArtifactPublisher = {}
ArtifactPublisher.__index = ArtifactPublisher

-- Begin a staged publication for one artifact. `liveRoots` are the
-- cache-relative roots the artifact owns and swaps wholesale at publish; the
-- root containing the completion marker must be listed last, so a process
-- crash mid-publish can never leave the new marker visible without its full
-- artifact (the marker root is moved aside and renamed into place last). Any
-- stale stage from a previous attempt, including an orphaned old root a crash
-- left behind, is removed first. The returned transaction exposes `stage` (a
-- CacheFs mirroring the live layout under the staging root), `publish()`, and
-- `abort()`.
function ArtifactPublisher.begin(cacheFs, name, liveRoots)
  assert(cacheFs and cacheFs.versionId, "begin requires a CacheFs")
  assert(type(name) == "string", "artifact name must be a string")
  assert(type(liveRoots) == "table" and #liveRoots >= 1, "liveRoots must list at least one owned root")
  local seen = {}
  for _, root in ipairs(liveRoots) do
    assert(type(root) == "string" and root ~= "", "each live root must be a non-empty path")
    assert(not seen[root], "duplicate live root: " .. root)
    seen[root] = true
  end
  local stage = CacheFs.forArtifactStage(cacheFs.versionId, name, cacheFs.backend)
  stage:removeTree("")
  return setmetatable({
    _cacheFs = cacheFs,
    _liveRoots = liveRoots,
    stage = stage,
  }, ArtifactPublisher)
end

-- Publish the staged artifact over the live roots. The live roots are moved
-- aside first, the staged roots are renamed into place, and only after every
-- rename lands are the aside roots and the stage removed. If any rename fails,
-- every root already moved into place is moved back to the stage and every
-- aside root is restored, so a failed publish leaves the previous artifact
-- byte-for-byte intact; the original error is then re-raised.
function ArtifactPublisher:publish()
  local cacheFs = self._cacheFs
  local stage = self.stage
  -- The host rename needs both destination parents to exist; createDirectory
  -- is mkdir -p. Done before anything moves, so a failure here leaves no state.
  for _, root in ipairs(self._liveRoots) do
    local parent = root:match("^(.*)/[^/]+$")
    if parent then
      cacheFs:createDirectory(parent)
      stage:createDirectory(parent)
    end
  end
  -- Phase 1: move every existing live root aside, inside the stage root. A
  -- failure rolls back every aside already made and re-raises.
  local aside = {}
  local ok, err = pcall(function()
    for _, root in ipairs(self._liveRoots) do
      if cacheFs:exists(root, "directory") then
        cacheFs.backend:replace(cacheFs:resolve(root), stage:resolve(root) .. CacheFs.STAGING_OLD_SUFFIX)
        aside[root] = true
      end
    end
  end)
  if not ok then
    for _, root in ipairs(self._liveRoots) do
      if aside[root] then
        pcall(
          cacheFs.backend.replace,
          cacheFs.backend,
          stage:resolve(root) .. CacheFs.STAGING_OLD_SUFFIX,
          cacheFs:resolve(root)
        )
      end
    end
    error(err, 0)
  end
  -- Phase 2: rename the staged roots into place, in the given order (marker
  -- root last).
  local movedIn = {}
  local ok, err = pcall(function()
    for _, root in ipairs(self._liveRoots) do
      cacheFs.backend:replace(stage:resolve(root), cacheFs:resolve(root))
      movedIn[#movedIn + 1] = root
    end
  end)
  if not ok then
    for index = #movedIn, 1, -1 do
      local root = movedIn[index]
      pcall(cacheFs.backend.replace, cacheFs.backend, cacheFs:resolve(root), stage:resolve(root))
    end
    for _, root in ipairs(self._liveRoots) do
      if aside[root] then
        pcall(
          cacheFs.backend.replace,
          cacheFs.backend,
          stage:resolve(root) .. CacheFs.STAGING_OLD_SUFFIX,
          cacheFs:resolve(root)
        )
      end
    end
    error(err, 0)
  end
  -- Phase 3: remove the stage, which now holds only the aside roots.
  stage:removeTree("")
  return true
end

-- Discard the staged artifact and any aside roots a failed publish left
-- behind. The live tree is never touched; the previous artifact (if any)
-- remains in place.
function ArtifactPublisher:abort()
  self.stage:removeTree("")
  return true
end

return ArtifactPublisher
