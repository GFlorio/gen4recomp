-- Static architecture guard: keeps package ownership in durable repository
-- guidance rather than relying on the current implementation layout.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    tags = { "architecture", "package-boundaries" },
  },
  tests = {},
}

local BASE = love.filesystem.getSourceBaseDirectory()

local function readFile(path)
  local handle = assert(io.open(BASE .. "/" .. path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function assertContains(contents, text, path)
  Assert.isTrue(contents:find(text, 1, true) ~= nil, path .. " must name " .. text)
end

function T.tests.package_ownership_is_explicit()
  local guidance = {
    ["libs/nds/AGENTS.md"] = { "libs/nds", "Nintendo DS", "Nitro" },
    ["libs/script/AGENTS.md"] = { "libs/script", "gen4.script" },
    ["libs/hgss/AGENTS.md"] = { "libs/hgss", "field", "presentation", "game" },
  }

  for path, terms in pairs(guidance) do
    local contents = readFile(path)
    for _, term in ipairs(terms) do
      assertContains(contents, term, path)
    end
  end

  local adr = readFile("docs/adr/runtime-package-boundaries.md")
  for _, term in ipairs({ "libs/nds", "libs/script", "libs/hgss", "gen4.script" }) do
    assertContains(adr, term, "docs/adr/runtime-package-boundaries.md")
  end

  local rootGuidance = readFile("AGENTS.md")
  for _, term in ipairs({ "libs/nds/AGENTS.md", "libs/script/AGENTS.md", "libs/hgss/AGENTS.md", "game" }) do
    assertContains(rootGuidance, term, "AGENTS.md")
  end

  local architecture = readFile("docs/architecture.md")
  for _, term in ipairs({ "libs/nds", "libs/script", "libs/hgss", "libs/assets", "romdump", "game" }) do
    assertContains(architecture, term, "docs/architecture.md")
  end
end

return T
