-- Stable error codes for the storage package (CacheFs, ArtifactPublisher).
-- Modules must reference the named constants, never bare literals, so a
-- rename stays in one place. Pure domain module: no love dependency.

local Errors = {}

Errors.CACHE_PATH_INVALID = "CACHE_PATH_INVALID"
Errors.CACHE_FILE_MISSING = "CACHE_FILE_MISSING"
Errors.CACHE_LUA_PARSE_FAILED = "CACHE_LUA_PARSE_FAILED"
Errors.CACHE_LUA_EVAL_FAILED = "CACHE_LUA_EVAL_FAILED"
Errors.CACHE_MKDIR_FAILED = "CACHE_MKDIR_FAILED"
Errors.CACHE_WRITE_FAILED = "CACHE_WRITE_FAILED"
Errors.CACHE_REMOVE_FAILED = "CACHE_REMOVE_FAILED"
Errors.CACHE_REPLACE_FAILED = "CACHE_REPLACE_FAILED"
Errors.CACHE_PUBLISH_ROLLBACK_INCOMPLETE = "CACHE_PUBLISH_ROLLBACK_INCOMPLETE"
Errors.CACHE_PUBLISH_CLEANUP_FAILED = "CACHE_PUBLISH_CLEANUP_FAILED"

return Errors
