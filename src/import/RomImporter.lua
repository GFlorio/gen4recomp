-- First-run import orchestration. This milestone implements only isReady, the
-- marker-plus-required-files readiness contract that RomFs and the boot flow
-- depend on (spec §6.4). The interactive state machine (startPath, update,
-- draw, filedropped) lands in Epic 8.
--
-- Readiness is a cheap check: the marker must exactly match the canonical
-- version's expected content, and a small fixed set of required outputs must
-- exist. It never loads the full index or reads large resources.

local GameVersion = require("src.core.GameVersion")
local CacheFs = require("src.import.CacheFs")
local RomExtractor = require("src.import.RomExtractor")

local RomImporter = {}

local REQUIRED_FILES = {
  "data/generated/rom_metadata.lua",
  "data/generated/romfs_index.lua",
  "data/generated/resolved_narcs.lua",
  "romfs/a/0/0/2",
  "romfs/a/0/4/1",
  "romfs/data/sound/gs_sound_data.sdat",
}

function RomImporter.isReady(versionId, cache)
  local info = GameVersion.info(versionId)
  cache = cache or CacheFs.forVersion(versionId)
  if cache:read("rom-dump.complete") ~= RomExtractor.markerContent(versionId, info.sha1) then
    return false
  end
  for _, path in ipairs(REQUIRED_FILES) do
    if not cache:exists(path, "file") then return false end
  end
  return true
end

return RomImporter
