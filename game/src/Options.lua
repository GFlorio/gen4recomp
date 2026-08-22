-- Pure command-line option parsing for the game app. Turns the LÖVE argv into
-- a normalized options table, rejecting unknown options, stray arguments, and
-- conflicting execution modes with a message. It holds no state and never
-- touches love, so main.lua can dispatch and the parser can be unit tested
-- off-runtime. Once the exact --test token appears the parser defers the whole
-- argv to the test command, which owns its own argument validation.

local Options = {}

-- Usage failure exit status; the same convention as the test command's
-- Cli.EXIT_USAGE so scripts/test.sh and the game agree on "bad invocation".
Options.EXIT_USAGE = 2

Options.USAGE = "usage: love game/ [--test ...] [--field [map]] [--actors] [--dev]"

---@class GameOptions
---@field test boolean
---@field field boolean|string|nil
---@field actors boolean
---@field dev boolean

-- argv: the array LÖVE passes to love.load.
---@param argv string[]|nil
---@return GameOptions|nil opts
---@return string|nil message
function Options.parse(argv)
  argv = argv or {}

  -- The test command (tests/runner/Cli.lua) accepts --test itself so the raw
  -- argv can be forwarded unchanged; it rejects everything it does not know
  -- with the usage exit status. Nothing here is validated once --test appears.
  for _, token in ipairs(argv) do
    if token == "--test" then
      return { test = true }
    end
  end

  local opts = { test = false, field = nil, actors = false, dev = false }

  local i = 1
  while i <= #argv do
    local option = argv[i]
    if option == "--field" then
      opts.field = true
      if argv[i + 1] and argv[i + 1]:sub(1, 2) ~= "--" then
        i = i + 1
        opts.field = argv[i]
      end
    elseif option == "--actors" then
      opts.actors = true
    elseif option == "--dev" then
      opts.dev = true
    elseif option:sub(1, 2) == "--" then
      return nil, "unknown option '" .. option .. "'\n" .. Options.USAGE
    else
      return nil, "unexpected argument '" .. option .. "'\n" .. Options.USAGE
    end
    i = i + 1
  end

  if opts.actors and opts.field ~= nil then
    return nil, "conflicting execution modes: --actors and --field\n" .. Options.USAGE
  end

  return opts
end

return Options
