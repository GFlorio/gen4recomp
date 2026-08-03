-- Pure command-line and environment option parsing (spec §15.2-§15.3). Turns the
-- LÖVE argv plus an injectable getenv into a normalized options table. It holds
-- no state and never touches love, so main.lua can dispatch and the parser can be
-- unit tested off-runtime. Flags win over their environment equivalents.

local GameVersion = require("src.core.GameVersion")

local Cli = {}

-- Boolean flag -> env var. Value flags (--import-rom, --version) are handled
-- separately because they consume the following argv token.
local BOOL_ENV = {
  importOnly = "G4RECOMP_IMPORT_ONLY",
  diagnostic = "G4RECOMP_DIAGNOSTIC",
  checkDump = "G4RECOMP_CHECK_DUMP",
}

local function truthyEnv(v)
  return v ~= nil and v ~= "" and v ~= "0"
end

local function validVersion(id)
  if id == nil then return nil end
  if not GameVersion.info(id) then
    error("unknown --version '" .. tostring(id) .. "' (expected heartgold or soulsilver)")
  end
  return id
end

-- argv: the array LÖVE passes to love.load. getenv: function(name) -> string|nil
-- (defaults to os.getenv; injectable for tests).
function Cli.parse(argv, getenv)
  argv = argv or {}
  getenv = getenv or os.getenv

  local opts = {
    test = false,
    importRom = nil,
    importOnly = false,
    version = nil,
    diagnostic = false,
    checkDump = false,
  }

  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--test" then
      opts.test = true
    elseif a == "--import-rom" then
      i = i + 1
      opts.importRom = argv[i] or error("--import-rom requires a path")
    elseif a == "--version" then
      i = i + 1
      opts.version = validVersion(argv[i] or error("--version requires an id"))
    elseif a == "--import-only" then
      opts.importOnly = true
    elseif a == "--diagnostic" then
      opts.diagnostic = true
    elseif a == "--check-dump" then
      opts.checkDump = true
    end
    -- Unknown tokens (e.g. LÖVE's own args, or value tokens already consumed)
    -- are ignored so the parser stays forgiving.
    i = i + 1
  end

  -- Environment fills any option a flag did not set (spec §15.2).
  if opts.importRom == nil then
    local envRom = getenv("G4RECOMP_IMPORT_ROM")
    if truthyEnv(envRom) then opts.importRom = envRom end
  end
  if opts.version == nil then
    local envVersion = getenv("G4RECOMP_VERSION")
    if truthyEnv(envVersion) then opts.version = validVersion(envVersion) end
  end
  for key, envName in pairs(BOOL_ENV) do
    if not opts[key] and truthyEnv(getenv(envName)) then opts[key] = true end
  end

  return opts
end

return Cli
