local Assert = require("tests.support.Assert")
local Sync = require("tools.sync_narc_catalog")

local T = {}

local VALID = [[
typedef enum NarcId {
    NARC_a_0_0_0 = 0,
    NARC_foo = 1,
    NARC_bar = 2,
} NarcId;

char *sNarcFileList[] = {
    "a/0/0/0",
    "a/0/0/1",
    "a/0/0/2",
};
extern char *sNarcFileList[];
]]

-- Load rendered catalog text in an empty environment, as the runtime does.
local function loadCatalog(text)
  local chunk = assert(loadstring(text))
  setfenv(chunk, {})
  return chunk()
end

function T.parses_symbols_ids_and_paths()
  local entries = Sync.parse(VALID)
  Assert.equal(#entries, 3)
  Assert.equal(entries[2].symbol, "NARC_foo")
  Assert.equal(entries[2].narcId, 1)
  Assert.equal(entries[2].path, "a/0/0/1")
  Assert.equal(entries[3].symbol, "NARC_bar")
  Assert.equal(entries[3].path, "a/0/0/2")
end

function T.rejects_non_contiguous_enum()
  local bad = VALID:gsub("NARC_bar = 2", "NARC_bar = 5")
  Assert.throws(function() Sync.parse(bad) end)
end

function T.rejects_enum_path_count_mismatch()
  local bad = VALID:gsub('    "a/0/0/2",\n', "")
  Assert.throws(function() Sync.parse(bad) end)
end

function T.render_is_deterministic_and_loadable()
  local entries = Sync.parse(VALID)
  local a = Sync.render(entries, "deadbeef")
  local b = Sync.render(entries, "deadbeef")
  Assert.equal(a, b, "render must be byte-identical across runs")

  local catalog = loadCatalog(a)
  Assert.equal(catalog.schema, 1)
  Assert.equal(catalog.source.commit, "deadbeef")
  Assert.equal(catalog.entries.NARC_foo.narcId, 1)
  Assert.equal(catalog.entries.NARC_bar.path, "a/0/0/2")
end

function T.render_requires_a_commit()
  local entries = Sync.parse(VALID)
  Assert.throws(function() Sync.render(entries, "") end)
end

return T
