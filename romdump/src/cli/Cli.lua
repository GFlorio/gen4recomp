-- Pure command-line option parsing. Turns the LÖVE argv into a normalized
-- options table. It holds no state and never touches love, so main.lua can
-- dispatch and the parser can be unit tested off-runtime.

local Cli = {}

-- argv: the array LÖVE passes to love.load.
function Cli.parse(argv)
  argv = argv or {}

  local opts = {
    test = false,
    testPrivate = false,
    importRom = nil,
    importOnly = false,
    checkDump = false,
    inspect = false,
    inspectSbc = false,
    analyzeMaps = false,
    buildCache = false,
    forceDump = false,
    allowCompileExclusions = false,
  }

  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--test" then
      opts.test = true
    elseif a == "--test-private" then
      opts.testPrivate = true
    elseif a == "--import-rom" then
      i = i + 1
      opts.importRom = argv[i] or error("--import-rom requires a path")
    elseif a == "--import-only" then
      opts.importOnly = true
    elseif a == "--check-dump" then
      opts.checkDump = true
    elseif a == "--inspect" then
      opts.inspect = true
    elseif a == "--inspect-sbc" then
      opts.inspectSbc = true
    elseif a == "--analyze-maps" then
      opts.analyzeMaps = true
    elseif a == "--allow-compile-exclusions" then
      opts.allowCompileExclusions = true
    elseif a == "--build-cache" then
      opts.buildCache = true
      if argv[i + 1] and argv[i + 1]:sub(1, 2) ~= "--" then
        i = i + 1
        opts.importRom = argv[i]
      end
    elseif a == "--forcedump" then
      opts.forceDump = true
      i = i + 1
      local path = argv[i]
      if not path or path:sub(1, 2) == "--" then
        error("--forcedump requires a ROM path")
      end
      opts.importRom = path
    end
    -- Unknown tokens (e.g. LÖVE's own args) are ignored so the parser stays forgiving.
    i = i + 1
  end

  return opts
end

return Cli
