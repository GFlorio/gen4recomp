-- Producer contract tests for the generated field-event binding manifest.
-- Inputs are already-normalized field bundles and compiled script metadata, so
-- these tests do not decode a ROM or read a runtime cache.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = { tests = {} }

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a producer error")
  Assert.isTrue(Errors.is(err), "expected a structured producer error")
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
end

local function compiler()
  local ok = pcall(require, "romdump.src.digest.script.BindingCompiler")
  Assert.isTrue(ok, "generated field binding compiler is missing")
  return require("romdump.src.digest.script.BindingCompiler")
end

local function fieldBundle(mapId, scriptBankId, events)
  return {
    mapId = mapId,
    field = {
      mapId = mapId,
      scriptBankId = scriptBankId,
      events = events or { objects = {}, background = {}, coordinates = {} },
    },
  }
end

local function scriptBundle(pairs)
  local resources = {}
  for _, pair in ipairs(pairs) do
    resources[#resources + 1] = {
      member = pair.member,
      scriptIndex = pair.scriptIndex,
    }
  end
  return { resources = resources }
end

local function sections(manifest, mapId)
  local map = assert(manifest.maps[mapId], "generated bindings must include map " .. mapId)
  Assert.notNil(map.objects, "map " .. mapId .. " must include object bindings")
  Assert.notNil(map.backgrounds, "map " .. mapId .. " must include background bindings")
  Assert.notNil(map.coordinates, "map " .. mapId .. " must include coordinate bindings")
  return map
end

-- Every compiled map contributes all three sections. Nonzero source events
-- are bound, while the zero marker and normalized hidden-item event remain
-- absent from the generated interaction tables.
function T.tests.emits_every_compiled_map_and_eligible_event()
  local manifest = compiler().compile(
    {
      fieldBundle(60, 842, {
        objects = {
          { objectEventId = 4, scriptId = 1 },
          { objectEventId = 5, scriptId = 0 },
        },
        background = {
          { index = 2, scriptId = 2 },
          { index = 3, scriptId = 3, hiddenItem = true },
        },
        coordinates = { { index = 7, scriptId = 4 } },
      }),
      fieldBundle(33, 900, {
        objects = { { objectEventId = 1, scriptId = 1 } },
        background = { { index = 0, scriptId = 2 } },
        coordinates = { { index = 5, scriptId = 3 } },
      }),
      fieldBundle(999, 901),
    },
    scriptBundle({
      { member = 842, scriptIndex = 0 },
      { member = 842, scriptIndex = 1 },
      { member = 842, scriptIndex = 2 },
      { member = 842, scriptIndex = 3 },
      { member = 900, scriptIndex = 0 },
      { member = 900, scriptIndex = 1 },
      { member = 900, scriptIndex = 2 },
    })
  )

  Assert.equal(manifest.schema, "g4-script-bindings-v1")
  local demo = sections(manifest, 60)
  local route = sections(manifest, 33)
  local empty = sections(manifest, 999)
  Assert.notNil(demo.objects[4])
  Assert.notNil(demo.backgrounds[2])
  Assert.notNil(demo.coordinates[7])
  Assert.isNil(demo.objects[5], "script-id-zero objects remain unbound")
  Assert.isNil(demo.backgrounds[3], "hidden-item backgrounds remain unbound")
  Assert.notNil(route.objects[1])
  Assert.notNil(route.backgrounds[0])
  Assert.notNil(route.coordinates[5])
  Assert.deepEqual(empty.objects, {})
  Assert.deepEqual(empty.backgrounds, {})
  Assert.deepEqual(empty.coordinates, {})
end

-- Targets are resolved from the existing public-ID policy. An explicit
-- override target wins for Elm even though the generated base has a different
-- public id.
function T.tests.reuses_public_ids_and_explicit_elm_override_target()
  local catalog = SourceCatalog.catalog()
  local mechanical = ScriptCompiler.publicId(900, 0, catalog)
  local curated = ScriptCompiler.publicId(843, 9, catalog)
  local manifest = compiler().compile(
    {
      fieldBundle(1, 900, {
        objects = { { objectEventId = 0, scriptId = 1 } },
        background = {},
        coordinates = {},
      }),
      fieldBundle(2, 843, {
        objects = { { objectEventId = 1, scriptId = 10 } },
        background = {},
        coordinates = {},
      }),
      fieldBundle(3, 843, {
        objects = { { objectEventId = 2, scriptId = 1 } },
        background = {},
        coordinates = {},
      }),
    },
    scriptBundle({
      { member = 900, scriptIndex = 0 },
      { member = 843, scriptIndex = 0 },
      { member = 843, scriptIndex = 9 },
    })
  )

  Assert.equal(manifest.maps[1].objects[0], mechanical)
  Assert.equal(manifest.maps[2].objects[1], curated)
  Assert.equal(manifest.maps[3].objects[2], "elms_lab.elm")
  Assert.isFalse(
    manifest.maps[3].objects[2] == ScriptCompiler.publicId(843, 0, catalog),
    "Elm must use its explicit override target"
  )
end

function T.tests.rejects_duplicate_event_id_with_context()
  local base = fieldBundle(60, 842, {
    objects = {
      { objectEventId = 4, scriptId = 1 },
      { objectEventId = 4, scriptId = 2 },
    },
    background = {},
    coordinates = {},
  })
  throwsCode("SCRIPT_BINDING_DUPLICATE", function()
    compiler().compile(
      { base },
      scriptBundle({
        { member = 842, scriptIndex = 0 },
        { member = 842, scriptIndex = 1 },
      })
    )
  end)
  for _, section in ipairs({ "background", "coordinates" }) do
    local events = { objects = {}, background = {}, coordinates = {} }
    events[section] = {
      { index = 2, scriptId = 1 },
      { index = 2, scriptId = 2 },
    }
    throwsCode("SCRIPT_BINDING_DUPLICATE", function()
      compiler().compile(
        { fieldBundle(60, 842, events) },
        scriptBundle({
          { member = 842, scriptIndex = 0 },
          { member = 842, scriptIndex = 1 },
        })
      )
    end)
  end
end

function T.tests.output_is_independent_of_source_iteration_order()
  local first = fieldBundle(60, 842, {
    objects = {
      { objectEventId = 4, scriptId = 1 },
      { objectEventId = 5, scriptId = 2 },
    },
    background = { { index = 2, scriptId = 3 } },
    coordinates = { { index = 7, scriptId = 4 } },
  })
  local second = fieldBundle(33, 900, {
    objects = { { objectEventId = 1, scriptId = 1 } },
    background = {},
    coordinates = {},
  })
  local scripts = scriptBundle({
    { member = 842, scriptIndex = 0 },
    { member = 842, scriptIndex = 1 },
    { member = 842, scriptIndex = 2 },
    { member = 842, scriptIndex = 3 },
    { member = 900, scriptIndex = 0 },
  })
  local reverseFirst = fieldBundle(60, 842, {
    objects = {
      { objectEventId = 5, scriptId = 2 },
      { objectEventId = 4, scriptId = 1 },
    },
    background = { { index = 2, scriptId = 3 } },
    coordinates = { { index = 7, scriptId = 4 } },
  })
  local reverseSecond = fieldBundle(33, 900, {
    objects = { { objectEventId = 1, scriptId = 1 } },
    background = {},
    coordinates = {},
  })
  local forward = compiler().compile({ first, second }, scripts)
  local reverse = compiler().compile({ reverseSecond, reverseFirst }, scripts)
  Assert.equal(LuaWriter.encode(forward), LuaWriter.encode(reverse))
end

return T
