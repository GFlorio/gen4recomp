-- Checked-in generated overrides must retain newly supported source commands
-- as semantic operations instead of hiding them behind placeholder dialogue.

local Assert = require("tests.support.Assert")
local Compiler = require("libs.engine.src.script.Compiler")

local T = {}

local OVERRIDE_PATHS = {
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_010.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_017.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0843.script_012.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0843.script_013.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0845.script_001.lua",
}

local VISIBILITY_BY_OPCODE = { [746] = false, [747] = true }
local ELM_OVERRIDE_PATH = "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_010.lua"

local function assertAuxiliaryUiOperations(value, moduleName, seen)
  if type(value) ~= "table" then
    return
  end
  local opcodes = value.provenance and value.provenance.opcodes
  if opcodes then
    for _, opcode in pairs(opcodes) do
      if VISIBILITY_BY_OPCODE[opcode] ~= nil or opcode == 746 then
        Assert.equal(value.op, "set_auxiliary_ui_visible", moduleName .. " has an incorrect auxiliary UI operation")
        Assert.equal(
          value.visible,
          VISIBILITY_BY_OPCODE[opcode],
          moduleName .. " has an incorrect auxiliary UI visibility"
        )
        seen[opcode] = true
      end
    end
  end
  for _, child in pairs(value) do
    assertAuxiliaryUiOperations(child, moduleName, seen)
  end
end

function T.supported_auxiliary_ui_opcodes_are_semantic_operations_in_overrides()
  local seen = {}
  for _, path in ipairs(OVERRIDE_PATHS) do
    local chunk = assert(loadfile(path))
    assertAuxiliaryUiOperations(chunk(), path, seen)
  end
  Assert.isTrue(seen[746])
  Assert.isTrue(seen[747])
end

function T.elm_route_override_has_complete_supported_coverage()
  local resource = assert(loadfile(ELM_OVERRIDE_PATH))()
  Assert.equal(resource.metadata.coverage.complete, true)
  Assert.equal(resource.metadata.coverage.unsupportedCount, 0)
  local graph = assert(Compiler.compile(resource))
  Assert.isFalse(graph.hasUnsupported)
end

function T.elm_route_override_delegates_fade_to_the_field_transition()
  local resource = assert(loadfile(ELM_OVERRIDE_PATH))()
  local operations = {}
  for _, step in ipairs(resource.steps) do
    operations[#operations + 1] = step.op
  end
  Assert.deepEqual(operations, { "play_sound", "warp", "wait_sound", "set_var", "stop" })
  Assert.equal(resource.steps[2].map, "MAP_NEW_BARK_ELMS_LAB_2F")
  Assert.deepEqual(
    { resource.steps[2].fieldX, resource.steps[2].fieldZ, resource.steps[2].facing, resource.steps[2].warp },
    { 12, 6, "west", 0 }
  )
  Assert.equal(resource.steps[4].variable, "VAR_UNK_407C")
  Assert.equal(resource.steps[4].value, 1)
end

-- The signpost overrides' std_signpost call must be the real call_common
-- node: with opcode 61 classified, common.signpost is fully supported, so
-- the generator must not collapse the call into an unsupported node
-- (coverage complete, zero unsupported nodes).
local SIGNPOST_OVERRIDE_PATHS = {
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_007.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_013.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_014.lua",
  "data/scripts/overrides/vanilla.hgss.scr_seq.0842.script_016.lua",
}

local function assertSignpostCallUncollapsed(value, moduleName, seen)
  if type(value) ~= "table" then
    return
  end
  local opcodes = value.provenance and value.provenance.opcodes
  if opcodes then
    for _, opcode in pairs(opcodes) do
      if opcode == 20 then
        Assert.equal(value.op, "call_common", moduleName .. " must keep the real std_signpost call")
        Assert.equal(value.target, "common.signpost", moduleName .. " must target the real common script")
        Assert.isNil(value.originalName, moduleName .. " must not collapse the std_signpost call")
        seen[#seen + 1] = value.target
      end
    end
  end
  for _, child in pairs(value) do
    assertSignpostCallUncollapsed(child, moduleName, seen)
  end
end

function T.signpost_overrides_keep_the_real_std_signpost_call()
  local seen = {}
  for _, path in ipairs(SIGNPOST_OVERRIDE_PATHS) do
    local chunk = assert(loadfile(path))
    local resource = chunk()
    assertSignpostCallUncollapsed(resource, path, seen)
    Assert.equal(resource.metadata.coverage.complete, true, path .. " must report complete coverage")
    Assert.equal(resource.metadata.coverage.unsupportedCount, 0, path .. " must have no unsupported nodes")
  end
  Assert.equal(#seen, 4, "every signpost override must keep its std_signpost call")
end

return { tests = T }
