-- Single source of truth for supported ROM identity: accepted SHA-1, game code,
-- display name, and expected size. Full SHA-1 is authoritative; size and game
-- code are friendly sanity checks only. Cache/save namespaces are structural
-- (the version id as a path component) and owned by the storage package. Pure
-- domain module.

local GameVersion = {}

GameVersion.VERSIONS = {
  heartgold = {
    id = "heartgold",
    label = "HeartGold",
    displayName = "Pokemon HeartGold",
    sha1 = "4fcded0e2713dc03929845de631d0932ea2b5a37",
    gameCode = "IPKE",
    expectedSize = 134217728,
  },
  soulsilver = {
    id = "soulsilver",
    label = "SoulSilver",
    displayName = "Pokemon SoulSilver",
    sha1 = "f8dc38ea20c17541a43b58c5e6d18c1732c7e582",
    gameCode = "IPGE",
    expectedSize = 134217728,
  },
}

GameVersion.ORDER = { "heartgold", "soulsilver" }

local current = nil

function GameVersion.set(versionId)
  assert(GameVersion.VERSIONS[versionId], "unknown version id: " .. tostring(versionId))
  current = versionId
end

function GameVersion.get()
  return current
end

function GameVersion.info(versionId)
  versionId = versionId or current
  assert(versionId, "no active version set")
  return GameVersion.VERSIONS[versionId]
end

function GameVersion.forSha1(hexSha1)
  local wanted = string.lower(hexSha1)
  for _, info in pairs(GameVersion.VERSIONS) do
    if info.sha1 == wanted then
      return info
    end
  end
  return nil
end

function GameVersion.forGameCode(gameCode)
  for _, info in pairs(GameVersion.VERSIONS) do
    if info.gameCode == gameCode then
      return info
    end
  end
  return nil
end

return GameVersion
