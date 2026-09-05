-- Structural contract for the private Oak timeline/profile and scene/profile
-- layout owners behind the existing controller/layout facades.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local REQUIRED_OWNERS = {
  "game/hgss/src/newgame/OakIntroTimeline.lua",
  "game/hgss/src/newgame/OakProfileFlow.lua",
  "game/hgss/src/newgame/OakSceneLayout.lua",
  "game/hgss/src/newgame/OakProfileLayout.lua",
}

function T.tests.oak_intro_has_explicit_private_state_and_layout_owners()
  for _, path in ipairs(REQUIRED_OWNERS) do
    local moduleName = path:gsub("/", "."):gsub("%.lua$", "")
    local ok, owner = pcall(require, moduleName)
    Assert.isTrue(ok, "Oak decomposition owner is not loadable: " .. path .. " (" .. tostring(owner) .. ")")
  end
end

return T
