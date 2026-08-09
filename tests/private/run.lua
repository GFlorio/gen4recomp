-- Private target-test runner. Invoked via `love game/ --test-private`. Unlike the
-- public suite it needs a real imported dump: it opens a RomFs for every ready
-- game version and runs each private test function with that RomFs. With no
-- ready dump it prints a skip and returns 0 so it is safe in any environment.

local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")
local RomFs = require("libs.rom.src.RomFs")

local MODULES = {
  "tests.private.elms_lab_test",
  "tests.private.elms_lab_compile_test",
  "tests.private.new_bark_test",
  "tests.private.field_camera_table_test",
  "tests.private.zone_events_test",
  "tests.private.terrain_surfaces_test",
  "tests.private.field_warps_test",
  "tests.private.neighbor_traversal_test",
  "tests.private.field_actors_test",
  "tests.private.field_actor_lifecycle_test",
  "tests.private.field_messages_test",
  "tests.private.field_dialogue_test",
  "tests.private.pre_script_interactions_test",
  "tests.private.pre_script_demo_path_test",
  "tests.private.script_corpus_test",
  "tests.private.new_bark_script_slice_test",
  "tests.private.field_save_resume_test",
  "tests.private.code_invariants_test",
}

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function readyVersions()
  local out = {}
  for _, id in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(id) then
      out[#out + 1] = id
    end
  end
  return out
end

local function run()
  local ready = readyVersions()
  if #ready == 0 then
    print("private: no ready dump; nothing to verify")
    return 0
  end

  local passed, failed = 0, 0
  for _, version in ipairs(ready) do
    print("== " .. version .. " ==")
    local romFs, err = RomFs.open(version)
    if not romFs then
      failed = failed + 1
      print("OPEN FAIL " .. version .. ": " .. tostring(err))
    else
      for _, modName in ipairs(MODULES) do
        local mod = require(modName)
        for _, name in ipairs(sortedKeys(mod)) do
          local ok, e = pcall(mod[name], romFs, version)
          if ok then
            passed = passed + 1
            print("ok   " .. modName .. " :: " .. name)
          else
            failed = failed + 1
            print("FAIL " .. modName .. " :: " .. name .. "\n    " .. tostring(e))
          end
        end
      end
      romFs:close()
    end
  end

  print(string.format("\nprivate: %d passed, %d failed", passed, failed))
  return failed
end

return { run = run }
