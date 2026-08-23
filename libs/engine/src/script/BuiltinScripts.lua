-- Definitions for scripts owned by the runtime rather than the generated ROM
-- corpus or the mod override layer. These resources still use the normal
-- script compiler and scheduler path.

local S = require("gen4.script")
local Bindings = require("libs.engine.src.script.Bindings")
local LuaWriter = require("libs.codec.src.LuaWriter")
local Sha256 = require("libs.engine.src.script.Sha256")

local BuiltinScripts = {}

---@return table<string, table>
function BuiltinScripts.all()
  return {
    [Bindings.CANONICAL_INERT_SCRIPT] = S.script({
      api = 1,
      id = Bindings.CANONICAL_INERT_SCRIPT,
      steps = { S.stop() },
    }),
  }
end

-- The digest covers the executable builtin projection, including ids and
-- script data, with the same deterministic serializer used by registry
-- fingerprints.
---@return string
function BuiltinScripts.contentHash()
  return Sha256.hex(LuaWriter.encode(BuiltinScripts.all()))
end

return BuiltinScripts
