-- The single owner of the raw extracted-dump identity contract: the generated
-- metadata/index paths, the completion marker path, and the schema identifiers
-- of those files. Producers (RomExtractor) and consumers (RomImporter
-- readiness, RomFs, CacheBuilder) must agree on these through this module;
-- the raw dump format itself stays romdump source-domain infrastructure, so
-- this contract lives here and not in libs/assets.

local RawDumpContract = {}

RawDumpContract.METADATA_PATH = "data/generated/rom_metadata.lua"
RawDumpContract.ROMFS_INDEX_PATH = "data/generated/romfs_index.lua"
RawDumpContract.OVERLAY_INDEX_PATH = "data/generated/overlay_index.lua"
RawDumpContract.MARKER_PATH = "rom-dump.complete"

RawDumpContract.METADATA_SCHEMA = 1
RawDumpContract.ROMFS_INDEX_SCHEMA = 1
RawDumpContract.OVERLAY_INDEX_SCHEMA = 1

return RawDumpContract
