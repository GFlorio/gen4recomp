-- First-run import orchestration and state machine. Two roles:
--
--   * RomImporter.isReady(versionId) -- the cheap marker-plus-required-files
--     readiness contract RomFs and the boot flow depend on. It never
--     loads the full index or reads large resources.
--
--   * An interactive/headless importer driving RomExtractor inside a coroutine:
--     validate the ROM fully (NdsRom.open: size, SHA-1, header, game code) BEFORE
--     any cache mutation, then extract, yielding periodically so the UI stays
--     responsive. The source ROM is released on every terminal state
--     and a single GC is run.
--
-- Progress is monotonic by construction (RomExtractor's stage fractions). All
-- love coupling is confined to the default `now` clock and the lazy draw helper.

local GameVersion = require("libs.rom.src.GameVersion")
local CacheFs = require("libs.rom.src.CacheFs")
local RomExtractor = require("libs.rom.src.RomExtractor")
local RomSource = require("libs.rom.src.RomSource")
local NdsRom = require("libs.rom.src.NdsRom")
local Errors = require("libs.rom.src.Errors")
local Hgss = require("data.manifests.hgss")

local RomImporter = {}
RomImporter.__index = RomImporter

local REQUIRED_FILES = {
  "data/generated/rom_metadata.lua",
  "data/generated/romfs_index.lua",
  "data/generated/overlay_index.lua",
  "romfs/a/0/0/2",
  "romfs/a/0/4/1",
  "romfs/data/sound/gs_sound_data.sdat",
}

-- `versions` lets the importer verify readiness against an injected catalog in
-- tests; production callers (RomFs, boot flow) use the default GameVersion.
function RomImporter.isReady(versionId, cache, versions)
  local info = (versions or GameVersion).info(versionId)
  if not info then
    return false
  end
  cache = cache or CacheFs.forVersion(versionId)
  if cache:read("rom-dump.complete") ~= RomExtractor.markerContent(versionId, info.sha1) then
    return false
  end
  for _, path in ipairs(REQUIRED_FILES) do
    if not cache:exists(path, "file") then
      return false
    end
  end
  return true
end

-- Yield roughly every 8ms of work during extraction.
local YIELD_INTERVAL = 0.008

local function defaultNow()
  if love and love.timer then
    return love.timer.getTime()
  end
  return 0
end

-- opts: { onComplete=, versions=, manifest=, cacheFactory=, now= }. All optional;
-- tests inject a synthetic version catalog, a FakeCache-backed cacheFactory, and
-- a static `now` (which disables yielding, so one update() runs to completion).
function RomImporter.new(opts)
  opts = opts or {}
  return setmetatable({
    _onComplete = opts.onComplete,
    _versions = opts.versions or GameVersion,
    _manifest = opts.manifest or Hgss,
    _cacheFactory = opts.cacheFactory or function(id)
      return CacheFs.forVersion(id)
    end,
    _now = opts.now or defaultNow,
    state = "idle",
    progress = 0,
  }, RomImporter)
end

function RomImporter:status()
  return {
    state = self.state,
    versionId = self._versionId,
    displayName = self._displayName,
    sourceName = self._sourceName,
    progress = self.progress or 0,
    stage = self._stage,
    stageLabel = self._stageLabel,
    detail = self._detail,
    report = self._report,
    error = self._error,
    errorCode = self._errorCode,
  }
end

function RomImporter:isBusy()
  return self.state == "reading" or self.state == "verifying" or self.state == "extracting"
end

function RomImporter:_setState(state)
  self.state = state
end

function RomImporter:_fail(err)
  if self._source then
    self._source:release()
  end
  self._source, self._co = nil, nil
  self._error = err
  self._errorCode = Errors.is(err) and err.code or nil
  self.state = "error"
  collectgarbage("collect")
end

function RomImporter:_complete(report)
  self._source, self._co = nil, nil
  self._report = report
  self.progress = 1
  self.state = "complete"
  collectgarbage("collect")
end

function RomImporter:_onProgress(p)
  self._stage = p.stage
  self._stageLabel = p.stageLabel
  self._detail = p.detail
  self.progress = p.overall
  local now = self._now()
  if now - (self._lastYield or 0) >= YIELD_INTERVAL then
    self._lastYield = now
    coroutine.yield()
  end
end

-- Build the coroutine that verifies then extracts. Kept off the frame thread so
-- update() can spread the work; validation completes before any cache write. An
-- explicitly supplied ROM is always dumped fresh -- boot-time reuse of a ready
-- cache is handled elsewhere (RomImporter.isReady), not here.
function RomImporter:_beginWork()
  local source = self._source
  self._co = coroutine.create(function()
    self:_setState("verifying")
    local rom, err = NdsRom.open(source, self._versions)
    if not rom then
      return self:_fail(err)
    end

    local info = rom:versionInfo()
    self._versionId = info.id
    self._displayName = info.displayName
    local cache = self._cacheFactory(info.id)

    self:_setState("extracting")
    self._lastYield = self._now()
    local extractor = RomExtractor.new(rom, info, cache, self._manifest, function(p)
      self:_onProgress(p)
    end)
    local report, exErr = extractor:run()
    rom:release()
    if not report then
      return self:_fail(exErr)
    end
    return self:_complete(report)
  end)
end

-- Start from an already-opened RomSource (used by tests and the start* helpers).
function RomImporter:startSource(source)
  assert(source, "startSource requires a RomSource")
  self._source = source
  self._sourceName = source:displayName()
  self._versionId, self._displayName = nil, nil
  self._report, self._error, self._errorCode = nil, nil, nil
  self._stage, self._stageLabel, self._detail = nil, nil, nil
  self._completeFired = false
  self.progress = 0
  self.state = "reading"
  self:_beginWork()
end

function RomImporter:startPath(path)
  self.state = "reading"
  local source, err = RomSource.fromPath(path)
  if not source then
    return self:_fail(err)
  end
  self:startSource(source)
end

function RomImporter:startDroppedFile(droppedFile)
  self.state = "reading"
  local source, err = RomSource.fromDroppedFile(droppedFile)
  if not source then
    return self:_fail(err)
  end
  self:startSource(source)
end

-- Drop handler with a friendly extension guard. Accepts a
-- raw .nds or a .zip containing one.
function RomImporter:filedropped(droppedFile)
  local name = droppedFile:getFilename() or ""
  if not name:lower():match("%.nds$") and not name:lower():match("%.zip$") then
    return self:_fail(Errors.new("IMPORT_NOT_NDS", "dropped file is not a .nds or .zip ROM: " .. name, { name = name }))
  end
  self:startDroppedFile(droppedFile)
end

-- Resume the import coroutine one slice. Safe to call in any state. Fires
-- onComplete exactly once, outside the coroutine, on reaching "complete".
function RomImporter:update()
  local co = self._co
  if co and coroutine.status(co) ~= "dead" then
    local ok, err = coroutine.resume(co)
    if not ok and self.state ~= "error" then
      self:_fail(err)
    end
  end
  if self.state == "complete" and not self._completeFired then
    self._completeFired = true
    if self._onComplete then
      self._onComplete(self._versionId, self._report)
    end
  end
end

return RomImporter
