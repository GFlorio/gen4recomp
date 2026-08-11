-- SHA-256 hex digest for compiled-script revision and fingerprint hashing.
-- A thin wrapper over love.data.hash: every supported path that computes a
-- script revision runs in a LÖVE 11.5 process (game boot and the LÖVE-hosted
-- test suite), where love.data is always present; there is no supported
-- bare-Lua execution path. The module never requires love, matching the
-- guarded-global pattern of romdump's Hashing.lua, and reuses its
-- HASHING_UNAVAILABLE failure code. This is a fingerprint, not a security
-- boundary.

local Errors = require("libs.rom.src.Errors")

local Sha256 = {}

-- Lowercase 64-character SHA-256 hex digest of a string.
---@param message string
---@return string
function Sha256.hex(message)
  assert(type(message) == "string", "sha256 input must be a string")
  if not (love and love.data) then
    Errors.raise("HASHING_UNAVAILABLE", "love.data is required for SHA-256 hashing", {})
  end
  local raw = love.data.hash("sha256", message)
  return (raw:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

return Sha256
