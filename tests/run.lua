-- Dependency-free test runner. Invoked via `love . --test`. Each listed module
-- returns a table mapping test-name -> function; every function is run in a
-- pcall and reported. run() returns the number of failed tests.

local MODULES = {
  "tests.errors_test",
  "tests.binary_reader_test",
  "tests.game_version_test",
  "tests.lua_writer_test",
  "tests.cache_fs_test",
  "tests.rom_source_test",
  "tests.nitro_fs_test",
  "tests.overlay_table_test",
  "tests.nds_rom_test",
  "tests.narc_test",
  "tests.hgss_manifest_test",
  "tests.map_matrix_test",
  "tests.map_catalog_test",
  "tests.map_resolver_test",
  "tests.area_data_test",
  "tests.field_light_profile_test",
  "tests.permission_grid_test",
  "tests.building_placement_test",
  "tests.land_data_test",
  "tests.fixed_test",
  "tests.nitro_file_test",
  "tests.nitro_dict_test",
  "tests.nsbtx_test",
  "tests.nsbtx_decoder_opts_test",
  "tests.mesh_compiler_test",
  "tests.building_transform_test",
  "tests.material_compiler_test",
  "tests.alpha_classifier_test",
  "tests.map_asset_compiler_test",
  "tests.map_asset_cache_test",
  "tests.map_cache_writer_test",
  "tests.texture_decoder_test",
  "tests.gx_display_list_test",
  "tests.ds_polygon_attr_test",
  "tests.ds_material_test",
  "tests.nsbmd_test",
  "tests.matrix4_test",
  "tests.camera3d_test",
  "tests.scene_mesh_test",
  "tests.matrix3_test",
  "tests.ds_lighting_test",
  "tests.render_queue_test",
  "tests.map_renderer_test",
  "tests.collision_grid_test",
  "tests.field_grid_test",
  "tests.debug_player_test",
  "tests.map_units_test",
  "tests.binary_writer_test",
  "tests.mesh_writer_test",
  "tests.png_writer_test",
  "tests.hashing_test",
  "tests.rom_extractor_test",
  "tests.rom_fs_test",
  "tests.cli_test",
  "tests.rom_importer_test",
  "tests.dump_audit_test",
  "tests.sync_narc_catalog_test",
}

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function run()
  local passed, failed = 0, 0
  local failures = {}

  for _, modName in ipairs(MODULES) do
    local ok, mod = pcall(require, modName)
    if not ok then
      failed = failed + 1
      failures[#failures + 1] = modName .. " (load): " .. tostring(mod)
      print("LOAD FAIL " .. modName .. ": " .. tostring(mod))
    else
      for _, name in ipairs(sortedKeys(mod)) do
        local testOk, err = pcall(mod[name])
        if testOk then
          passed = passed + 1
        else
          failed = failed + 1
          local label = modName .. " :: " .. name
          failures[#failures + 1] = label .. "\n    " .. tostring(err)
          print("FAIL " .. label .. "\n    " .. tostring(err))
        end
      end
    end
  end

  print(string.format("\n%d passed, %d failed", passed, failed))
  for _, f in ipairs(failures) do print("  - " .. f) end
  return failed
end

return { run = run }
