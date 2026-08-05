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
    build = false,
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
    elseif a == "--build" then
      opts.build = true
    end
    -- Unknown tokens (e.g. LÖVE's own args) are ignored so the parser stays forgiving.
    i = i + 1
  end

  return opts
end

return Cli
