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
  "libs.rom.tests.artifact_publisher_test",
  "libs.rom.tests.save_fs_test",
  "libs.rom.tests.rom_source_test",
  "libs.rom.tests.nitro_fs_test",
  "libs.rom.tests.overlay_table_test",
  "libs.rom.tests.overlay_compression_test",
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
  "tests.hgss_reference_test",
  "libs.assets.tests.field_light_profile_test",
  "libs.assets.tests.hgss_camera_table_test",
  "libs.assets.tests.hgss_bdhc_test",
  "libs.assets.tests.zone_events_test",
  "libs.assets.tests.permission_grid_test",
  "libs.assets.tests.map_asset_cache_test",
  "libs.assets.tests.cache_readiness_test",
  "libs.assets.tests.validate_test",
  "libs.assets.tests.mesh_writer_test",
  "libs.assets.tests.png_writer_test",
  "libs.assets.tests.map_matrix_test",
  -- libs/engine
  "libs.engine.tests.camera_history_test",
  "libs.engine.tests.field_camera_test",
  "libs.engine.tests.field_zoom_test",
  "libs.engine.tests.field_viewport_test",
  "libs.engine.tests.scene_mesh_test",
  "libs.engine.tests.ds_lighting_test",
  "libs.engine.tests.render_queue_test",
  "libs.engine.tests.scene_assembly_test",
  "libs.engine.tests.billboard_transform_test",
  "libs.engine.tests.map_renderer_test",
  "libs.engine.tests.collision_grid_test",
  "libs.engine.tests.field_grid_test",
  "libs.engine.tests.neighbor_ring_test",
  "libs.engine.tests.gpu_asset_pool_test",
  "libs.engine.tests.map_scene_loader_test",
  "libs.engine.tests.field_coverage_planner_test",
  "libs.engine.tests.terrain_surface_test",
  "libs.engine.tests.field_coordinates_test",
  "libs.engine.tests.field_region_test",
  "libs.engine.tests.field_map_loader_test",
  "libs.engine.tests.field_input_test",
  "libs.engine.tests.field_player_test",
  "libs.engine.tests.warp_system_test",
  "libs.engine.tests.field_transition_test",
  "libs.engine.tests.field_session_test",
  "libs.engine.tests.field_save_test",
  "libs.engine.tests.field_save_store_test",
  "libs.engine.tests.field_actor_asset_provider_test",
  "libs.engine.tests.field_event_state_test",
  "libs.engine.tests.field_object_actor_test",
  "libs.engine.tests.field_actor_manager_test",
  "libs.engine.tests.field_actor_pose_test",
  "libs.engine.tests.field_actor_mesh_test",
  "libs.engine.tests.field_actor_draw_test",
  "libs.engine.tests.field_player_visual_test",
  "libs.engine.tests.field_scenario_test",
  "libs.engine.tests.field_interaction_resolver_test",
  "libs.engine.tests.pre_script_interaction_adapter_test",
  "libs.engine.tests.field_message_provider_test",
  "libs.engine.tests.dialogue_layout_test",
  "libs.engine.tests.field_dialogue_theme_test",
  "libs.engine.tests.field_dialogue_controller_test",
  "libs.engine.tests.field_dialogue_renderer_test",
  "libs.engine.tests.script_dialogue_host_test",
  "libs.engine.tests.script.dsl_tests",
  "libs.engine.tests.script.validator_tests",
  "libs.engine.tests.script.compiler_tests",
  "libs.engine.tests.script.loader_tests",
  "libs.engine.tests.script.docgen_test",
  "libs.engine.tests.script.scheduler_tests",
  "libs.engine.tests.script.save_tests",
  "libs.engine.tests.script.task_tests",
  "libs.engine.tests.script.context_tests",
  "libs.engine.tests.script.composition_tests",
  "libs.engine.tests.script.binding_tests",
  "libs.engine.tests.script.movement_tests",
  "libs.engine.tests.script.audio_fade_warp_tests",
  "libs.engine.tests.script.world_state_tests",
  -- game
  "game.tests.app_boot_test",
  "game.tests.app_state_test",
  "game.tests.field_state_dispose_test",
  "game.tests.spawns_manifest_test",
  -- romdump
  "romdump.tests.cli_test",
  "romdump.tests.runner_build_test",
  -- romdump/src/digest
  "romdump.tests.neighbor_plan_test",
  "romdump.tests.neighbor_chunk_compiler_test",
  "romdump.tests.map_catalog_test",
  "romdump.tests.map_resolver_test",
  "romdump.tests.map_analysis_test",
  "romdump.tests.area_data_test",
  "romdump.tests.building_placement_test",
  "romdump.tests.building_transform_test",
  "romdump.tests.build_model_anim_list_test",
  "romdump.tests.land_data_test",
  "romdump.tests.nitro_file_test",
  "romdump.tests.nitro_dict_test",
  "romdump.tests.nsbtx_test",
  "romdump.tests.nsbtx_decoder_opts_test",
  "romdump.tests.mesh_compiler_test",
  "romdump.tests.material_compiler_test",
  "romdump.tests.alpha_classifier_test",
  "romdump.tests.map_asset_compiler_test",
  "romdump.tests.world_manifest_test",
  "romdump.tests.map_cache_writer_test",
  "romdump.tests.texture_decoder_test",
  "romdump.tests.gx_display_list_test",
  "romdump.tests.ds_polygon_attr_test",
  "romdump.tests.ds_material_test",
  "romdump.tests.nsbmd_test",
  "romdump.tests.nsbmd_sbc_test",
  "romdump.tests.sbc_inventory_test",
  "romdump.tests.nsbmd_joint_transforms_test",
  "romdump.tests.nsbmd_static_transforms_test",
  "romdump.tests.map_units_test",
  "romdump.tests.hashing_test",
  "romdump.tests.field_camera_compiler_test",
  "romdump.tests.field_map_data_compiler_test",
  "romdump.tests.terrain_inspector_test",
  "romdump.tests.field_actor_graphics_test",
  "romdump.tests.field_actor_model_test",
  "romdump.tests.field_actor_static_model_test",
  "romdump.tests.field_actor_frames_test",
  "romdump.tests.field_actor_timeline_test",
  "romdump.tests.field_actor_cache_writer_test",
  -- libs/assets (message/font derived classes)
  "libs.assets.tests.field_message_text_test",
  -- romdump (message/font digesters and compilers)
  "romdump.tests.field_message_bank_test",
  "romdump.tests.field_message_tokenizer_test",
  "romdump.tests.field_font_decoder_test",
  "romdump.tests.field_message_compiler_test",
  "romdump.tests.field_font_compiler_test",
  "romdump.tests.script_binary_decoder_test",
  "romdump.tests.script_cache_writer_test",
  "romdump.tests.script_translator_test",
}

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

-- Every test module on disk must be registered above; a suite that is never
-- run cannot guard the code it covers. Enumerated through love.filesystem
-- (the runner's only invocation path); a no-op when love is absent.
local TEST_DIRS = {
  { path = "libs/rom/tests", prefix = "libs.rom.tests" },
  { path = "libs/math/tests", prefix = "libs.math.tests" },
  { path = "libs/assets/tests", prefix = "libs.assets.tests" },
  { path = "libs/engine/tests", prefix = "libs.engine.tests" },
  { path = "game/tests", prefix = "game.tests" },
  { path = "romdump/tests", prefix = "romdump.tests" },
}

local function assertAllTestModulesRegistered()
  if love == nil or love.filesystem == nil then
    return
  end
  local registered = {}
  for _, modName in ipairs(MODULES) do
    registered[modName] = true
  end
  for _, dir in ipairs(TEST_DIRS) do
    local entries = love.filesystem.getDirectoryItems(dir.path)
    for _, name in ipairs(entries) do
      local moduleName = name:match("^(.*%.lua)$")
      if moduleName ~= nil then
        moduleName = dir.prefix .. "." .. moduleName:sub(1, -5)
        assert(registered[moduleName], "test module exists but is not registered in tests/run.lua: " .. moduleName)
      end
    end
  end
end

local function run()
  assertAllTestModulesRegistered()
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
  for _, f in ipairs(failures) do
    print("  - " .. f)
  end
  return failed
end

return { run = run }
