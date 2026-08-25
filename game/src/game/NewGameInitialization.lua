-- The fresh-New-Game-only source event initializer handoff: applies the
-- generated `_std_init` event operations to a finalized Oak candidate's
-- authoritative worldState before FieldState/FieldRuntime construct any
-- actor. It never creates a second event-state copy, never touches
-- player/profile/options, and never runs on Continue. When no artifact is
-- supplied it loads the generated per-version cache itself, following the
-- same "assert the cache is warm" boot convention as the other generated
-- caches FieldRuntime/OakIntroComposition already load.

local CacheFs = require("libs.storage.src.CacheFs")
local NewGameInitCache = require("libs.assets.src.NewGameInitCache")

local NewGameInitialization = {}

local function loadArtifact(versionId)
  assert(type(versionId) == "string", "NewGameInitialization requires a versionId to load the startup artifact")
  local cacheFs = CacheFs.forVersion(versionId)
  local artifact = assert(
    cacheFs:loadLua(NewGameInitCache.path()),
    "fresh-game startup initializer cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(NewGameInitCache.validate(artifact), "fresh-game startup initializer cache is invalid")
  return artifact
end

-- Mutates and returns the same candidate: only worldState changes, and only
-- through the artifact's ordered `set_flag` event operations. `artifact` is
-- an explicit testing seam; production Oak completion omits it so this
-- module owns loading the generated per-version cache.
---@param candidate table finalized fresh-New-Game candidate
---@param artifact table? generated startup artifact; loaded from cache when omitted
---@return table candidate
function NewGameInitialization.apply(candidate, artifact)
  assert(type(candidate) == "table", "apply requires a candidate")
  assert(
    type(candidate.worldState) == "table"
      and type(candidate.worldState.setFlag) == "function"
      and type(candidate.worldState.serialize) == "function",
    "apply requires a candidate with an authoritative worldState"
  )
  artifact = artifact or loadArtifact(candidate.versionId)
  assert(NewGameInitCache.validate(artifact), "fresh-game startup initializer artifact is invalid")

  for _, operation in ipairs(artifact.eventOperations) do
    assert(operation.op == "set_flag", "unsupported startup event operation " .. tostring(operation.op))
    candidate.worldState:setFlag(operation.id)
  end
  return candidate
end

return NewGameInitialization
