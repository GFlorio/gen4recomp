-- Automatic emote-to-sound-effect catalog: an exact-or-silent evidence
-- boundary for movement emotes. A caller looks up a semantic emote kind and
-- gets back either the exact source-proven runtime audio effect id or nil.
-- There is no default/fallback effect: absence of a proven mapping is a
-- deliberate, permanent "no automatic sound" answer, not a gap to guess at.
-- Pure domain module: no love dependency.

---@class EmoteSoundCatalog
---@field provenMappings table<string, string> semantic emote kind -> exact runtime audio effect id
local EmoteSoundCatalog = {}
EmoteSoundCatalog.__index = EmoteSoundCatalog

---@param provenMappings table<string, string>? semantic emote kind -> exact effect id; only source-authenticated entries belong here
function EmoteSoundCatalog.new(provenMappings)
  assert(provenMappings == nil or type(provenMappings) == "table", "provenMappings must be a table or nil")
  return setmetatable({ provenMappings = provenMappings or {} }, EmoteSoundCatalog)
end

-- Returns the exact proven audio effect id for a semantic emote kind, or nil
-- when no authoritative source mapping has been established. Callers must
-- not substitute a default/generic effect when this returns nil.
---@param kind string
---@return string|nil
function EmoteSoundCatalog:effectFor(kind)
  return self.provenMappings[kind]
end

return EmoteSoundCatalog
