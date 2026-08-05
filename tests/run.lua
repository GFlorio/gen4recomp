-- Dependency-free test runner. Invoked via `love game/ --test`. Each listed
-- module returns a table mapping test-name -> function; every function is run
-- in a pcall and reported. run() returns the number of failed tests. Unit tests
-- live beside their library (libs/<lib>/tests); this list is the aggregate.

local MODULES = {
  -- libs/rom
  "libs.rom.tests.errors_test",
  "libs.rom.tests.binary_reader_test",
  "libs.rom.tests.binary_writer_test",
  "libs.rom.tests.lua_writer_test",
  "libs.rom.tests.game_version_test",
  "libs.rom.tests.cache_fs_test",
  "libs.rom.tests.rom_source_test",
  "libs.rom.tests.nitro_fs_test",
  "libs.rom.tests.overlay_table_test",
  "libs.rom.tests.nds_rom_test",
  "libs.rom.tests.narc_test",
  "libs.rom.tests.rom_extractor_test",
  "libs.rom.tests.rom_fs_test",
  "libs.rom.tests.rom_importer_test",
  "libs.rom.tests.dump_audit_test",
  -- libs/math
  "libs.math.tests.matrix4_test",
  "libs.math.tests.matrix3_test",
  "libs.math.tests.fixed_point_test",
  -- libs/assets
  "libs.assets.tests.hgss_manifest_test",
  "libs.assets.tests.map_matrix_test",
  "libs.assets.tests.neighbor_plan_test",
  "libs.assets.tests.map_catalog_test",
  "libs.assets.tests.map_resolver_test",
  "libs.assets.tests.area_data_test",
  "libs.assets.tests.field_light_profile_test",
  "libs.assets.tests.permission_grid_test",
  "libs.assets.tests.building_placement_test",
  "libs.assets.tests.building_transform_test",
  "libs.assets.tests.build_model_anim_list_test",
  "libs.assets.tests.land_data_test",
  "libs.assets.tests.nitro_file_test",
  "libs.assets.tests.nitro_dict_test",
  "libs.assets.tests.nsbtx_test",
  "libs.assets.tests.nsbtx_decoder_opts_test",
  "libs.assets.tests.mesh_compiler_test",
  "libs.assets.tests.material_compiler_test",
  "libs.assets.tests.alpha_classifier_test",
  "libs.assets.tests.map_asset_compiler_test",
  "libs.assets.tests.map_asset_cache_test",
  "libs.assets.tests.world_manifest_test",
  "libs.assets.tests.map_cache_writer_test",
  "libs.assets.tests.texture_decoder_test",
  "libs.assets.tests.gx_display_list_test",
  "libs.assets.tests.ds_polygon_attr_test",
  "libs.assets.tests.ds_material_test",
  "libs.assets.tests.nsbmd_test",
  "libs.assets.tests.nsbmd_static_transforms_test",
  "libs.assets.tests.map_units_test",
  "libs.assets.tests.mesh_writer_test",
  "libs.assets.tests.png_writer_test",
  "libs.assets.tests.hashing_test",
  "libs.assets.tests.sync_narc_catalog_test",
  -- libs/engine
  "libs.engine.tests.camera3d_test",
  "libs.engine.tests.scene_mesh_test",
  "libs.engine.tests.ds_lighting_test",
  "libs.engine.tests.render_queue_test",
  "libs.engine.tests.map_renderer_test",
  "libs.engine.tests.collision_grid_test",
  "libs.engine.tests.field_grid_test",
  "libs.engine.tests.debug_player_test",
  "libs.engine.tests.neighbor_ring_test",
  -- romdump
  "romdump.tests.cli_test",
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
