-- Repository-level checks for the final package documentation and static gates.

local Assert = require("tests.support.Assert")
local DocGen = require("tools.gen-script-docs.DocGen")

local T = {
  metadata = {
    tags = { "architecture", "repository-tooling" },
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
  Assert.isTrue(contents:find(text, 1, true) ~= nil, path .. " must contain " .. text)
end

local function assertNotContains(contents, text, path)
  Assert.isNil(contents:find(text, 1, true), path .. " must not contain " .. text)
end

function T.tests.current_architecture_docs_have_no_transitional_owner()
  local paths = {
    "AGENTS.md",
    "game/AGENTS.md",
    "docs/architecture.md",
    "docs/data-provenance.md",
  }
  for _, path in ipairs(paths) do
    local contents = readFile(path)
    assertNotContains(contents, "libs/engine", path)
    assertNotContains(contents, "libs.engine", path)
    assertNotContains(contents, "migration-only", path)
    assertNotContains(contents, "during migration", path)
    assertNotContains(contents, "transitional physical", path)
  end

  local architecture = readFile("docs/architecture.md")
  for _, term in ipairs({
    "libs/nds",
    "libs/script",
    "libs/hgss",
    "game ─────────► libs/hgss, libs/script, libs/assets, foundations",
    "game ── launcher/import only ──► romdump",
  }) do
    assertContains(architecture, term, "docs/architecture.md")
  end

  local rootGuidance = readFile("AGENTS.md")
  assertContains(rootGuidance, "game depends on HGSS mechanisms, not Nintendo implementation details", "AGENTS.md")
end

function T.tests.invariant_and_script_tool_paths_use_final_owners()
  local invariants = readFile("scripts/check-invariants.sh")
  for _, path in ipairs({
    "libs/nds/src/nitro/g3d/Nsbmd.lua",
    "romdump/src/digest/MaterialCompiler.lua",
    "romdump/src/digest/MeshCompiler.lua",
    "libs/nds/src/love/GxRenderer.lua",
    "libs/nds/src/love/shaders/map.glsl",
  }) do
    assertContains(invariants, path, "scripts/check-invariants.sh")
  end
  assertNotContains(invariants, "libs/engine", "scripts/check-invariants.sh")

  local launcher = readFile("scripts/gen-script-docs.sh")
  assertContains(launcher, "libs/script/src/Schema.lua", "scripts/gen-script-docs.sh")
  assertNotContains(launcher, "libs/engine", "scripts/gen-script-docs.sh")

  local generator = readFile("tools/gen-script-docs/DocGen.lua")
  assertContains(generator, 'require("libs.script.src.Schema")', "tools/gen-script-docs/DocGen.lua")
  assertNotContains(generator, "libs.engine", "tools/gen-script-docs/DocGen.lua")
end

function T.tests.script_docs_match_the_final_schema_source()
  local generated = DocGen.render()
  local checkedIn = readFile("docs/script-api-v1.md")
  Assert.equal(checkedIn, generated, "script API documentation must be generated from libs/script")
end

function T.tests.codehealth_uses_tracked_production_discovery()
  Assert.isNil(love.filesystem.getInfo("libs/engine"), "the removed engine package must not exist")

  local codehealth = readFile("scripts/codehealth.sh")
  assertContains(codehealth, "git ls-files '*.lua'", "scripts/codehealth.sh")
  assertNotContains(codehealth, "libs/engine", "scripts/codehealth.sh")
end

return T
