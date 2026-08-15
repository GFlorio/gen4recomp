-- Deterministic field-UI compilation and cache publication using synthetic
-- source archives: every decode path (char/screen/palette/cell/animation)
-- runs against hand-built members, malformed source and generated metadata
-- are rejected at the owning layer, and the publication matrix (stage write
-- failure, stage validation failure, first/second publish rename failure)
-- reuses ArtifactPublisher through a FakeCache so the previous ready class
-- stays readable and the marker never claims an incomplete class.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldUiCompiler = require("romdump.src.digest.FieldUiCompiler")
local FieldUiCacheWriter = require("romdump.src.digest.FieldUiCacheWriter")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local PngReader = require("tests.support.PngReader")

local T = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end
local function swap4(s)
  return s:reverse()
end

local function lz10Wrap(data)
  local head = string.char(0x10, #data % 65536 % 256, math.floor(#data / 256) % 256, math.floor(#data / 65536) % 256)
  local flags = string.char(0)
  local chunks = {}
  for i = 1, #data, 8 do
    local chunk = data:sub(i, math.min(i + 7, #data))
    chunks[#chunks + 1] = flags .. chunk
  end
  return head .. table.concat(chunks)
end

local function container(magic, blocks)
  local body = {}
  local size = 0x10
  for _, blk in ipairs(blocks) do
    body[#body + 1] = blk
    size = size + #blk
  end
  return magic .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(size) .. u16(0x10) .. u16(#blocks) .. table.concat(body)
end

local function block(magic, payload)
  return swap4(magic) .. u32(8 + #payload) .. payload
end

-- 4bpp char data: `tiles` tiles, tile t all value (t % 15) + 1.
local function charData(tiles)
  local payload = u16(8) .. u16(0x20) .. u32(3) .. u16(0) .. u16(0) .. u32(0) .. u32(tiles * 32) .. u32(0x18)
  local body = {}
  for t = 0, tiles - 1 do
    body[#body + 1] = string.rep(string.char((t % 15 + 1) * 0x11), 32)
  end
  return container("RGCN", { block("CHAR", payload .. table.concat(body)) })
end

local function screenData(entries)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return container("RCSN", { block("SCRN", u16(256) .. u16(192) .. u32(0) .. u32(#entries * 2) .. table.concat(body)) })
end

-- A full 32x24-tile screen filled with one entry value.
local function fullScreen(entry)
  local entries = {}
  for i = 1, 768 do
    entries[i] = entry
  end
  return screenData(entries)
end

local function paletteData(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  -- RLCN-wrapped TTLP: the TTLP chunk magic is stored in its normal order.
  -- Layout (per FieldFontDecoder): depth u32, unk u32, paletteBytes u32,
  -- dataOffset u32; the colors follow the 20-byte field area, so the data
  -- offset is 16.
  local ttlp = "TTLP" .. u32(8 + 20 + #body) .. u32(3) .. u32(0) .. u32(#colors * 2) .. u32(16) .. table.concat(body)
  return "RLCN" .. string.char(0xFF, 0xFE) .. u16(0x0100) .. u32(0x10 + #ttlp) .. u16(0x10) .. u16(1) .. ttlp
end

local function cellData(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16(o.y) .. u16(o.x) .. u16(o.tile + o.pal * 4096)
  end
  return container("RECN", {
    block("CEBK", u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)),
  })
end

local function animData(frames)
  local anims = u16(1) .. u16(#frames) .. u32(0x18) .. u32(0x28) .. u32(0x28 + 8 * #frames) .. string.rep("\0", 8)
  local anim = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks = {}
  local frameData = {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return container("RNAN", { block("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData)) })
end

local function narc(members)
  local btaf = u16(#members) .. u16(0)
  local offset = 0
  local sizes = {}
  for _, bytes in ipairs(members) do
    sizes[#sizes + 1] = #bytes
    offset = offset + #bytes
  end
  local running = 0
  for _, size in ipairs(sizes) do
    btaf = btaf .. u32(running) .. u32(running + size)
    running = running + size
  end
  local gmif = table.concat(members)
  local function narcBlock(magic, payload)
    return magic .. u32(8 + #payload) .. payload
  end
  local btafBlock = narcBlock("BTAF", btaf)
  local gmifBlock = narcBlock("GMIF", gmif)
  return "NARC"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x10 + #btafBlock + #gmifBlock)
    .. u16(0x10)
    .. u16(2)
    .. btafBlock
    .. gmifBlock
end

-- A synthetic RomFs whose four UI NARCs carry minimal valid members: 20
-- dialogue frames, 25 signpost types, the four wayfinding members, the start
-- menu bg + cursor, and the card front.
local function fixture()
  local function frameMembers(count)
    local members = {}
    for i = 1, count do
      members[i] = lz10Wrap(charData(20))
    end
    for i = 1, count do
      members[count + i] = lz10Wrap(paletteData({ 0x7FFF, 0x296B }))
    end
    return members
  end
  local startMenuMembers = {}
  startMenuMembers[13] = lz10Wrap(charData(128))
  startMenuMembers[14] = lz10Wrap(fullScreen(0xE000))
  startMenuMembers[16] = lz10Wrap(paletteData({ 0x7FFF, 0x001F }))
  startMenuMembers[62] = lz10Wrap(paletteData({ 0x7FFF, 0x001F }))
  startMenuMembers[63] = lz10Wrap(cellData({ { x = 0, y = 0, tile = 0, pal = 0 } }))
  startMenuMembers[64] = lz10Wrap(animData({ { duration = 3, cell = 0 }, { duration = 3, cell = 0 } }))
  startMenuMembers[65] = lz10Wrap(charData(17))
  local startMenu = {}
  for i = 1, 65 do
    startMenu[i] = startMenuMembers[i] or string.rep("\0", 4)
  end

  local signpostMembers = {}
  signpostMembers[1] = charData(20)
  signpostMembers[2] = paletteData({ 0x7FFF, 0x001F })
  for _, memberId in ipairs({ 2, 3, 0x21, 0x22 }) do
    signpostMembers[memberId + 1] = charData(26)
  end
  local signposts = {}
  for i = 1, 0x23 do
    signposts[i] = signpostMembers[i] or string.rep("\0", 4)
  end

  local card = {}
  for i = 1, 48 do
    card[i] = string.rep("\0", 4)
  end
  card[42] = charData(128)
  card[48] = fullScreen(0xE000)
  card[12] = paletteData({ 0x7FFF, 0x001F })

  local function narcFile(alias)
    local members
    if alias == "start_menu" then
      members = startMenu
    elseif alias == "dialogue_frames" then
      members = {}
      for i = 1, 47 do
        members[i] = string.rep("\0", 4)
      end
      for i = 1, 20 do
        members[2 + i] = lz10Wrap(charData(20))
      end
      for i = 1, 20 do
        members[26 + i] = lz10Wrap(paletteData({ 0x7FFF, 0x296B }))
      end
    elseif alias == "signpost_graphics" then
      members = signposts
    else
      members = card
    end
    return narc(members)
  end
  local archives = {
    start_menu = { fileId = 10, narcId = 14, path = "a/0/1/4", symbol = "NARC_a_0_1_4", alias = "start_menu" },
    dialogue_frames = { fileId = 11, narcId = 38, path = "a/0/3/8", symbol = "NARC_a_0_3_8", alias = "dialogue_frames" },
    signpost_graphics = {
      fileId = 12,
      narcId = 36,
      path = "a/0/3/6",
      symbol = "NARC_a_0_3_6",
      alias = "signpost_graphics",
    },
    trainer_card_graphics = {
      fileId = 13,
      narcId = 49,
      path = "a/0/4/9",
      symbol = "NARC_a_0_4_9",
      alias = "trainer_card_graphics",
    },
  }
  local romFs = {
    resolvedNarc = function(_, alias)
      return archives[alias]
    end,
    read = function(_, fileId)
      if fileId == 10 then
        return narcFile("start_menu")
      end
      if fileId == 11 then
        return narcFile("dialogue_frames")
      end
      if fileId == 12 then
        return narcFile("signpost_graphics")
      end
      if fileId == 13 then
        return narcFile("trainer_card_graphics")
      end
      Assert.fail("unexpected read " .. tostring(fileId))
    end,
    openNarc = function(_, alias)
      local Narc = require("romdump.src.source.Narc")
      return assert(Narc.open(narcFile(alias), alias))
    end,
    metadata = function()
      return { sha1 = "rom-sha" }
    end,
    version = function()
      return "heartgold"
    end,
  }
  return romFs, function()
    return "member-sha"
  end, function()
    return "dependency-sha"
  end
end

function T.compiles_the_manifest_and_all_assets()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(bundle.manifest.schema, FieldUiAssetCache.SCHEMA)
  Assert.equal(bundle.manifest.dialogueFrames.count, 20)
  Assert.equal(bundle.manifest.signposts.types[0].sourceType, 0)
  Assert.isTrue(bundle.manifest.signposts.types[0].wayfinding ~= nil)
  Assert.isNil(bundle.manifest.signposts.types[2].wayfinding)
  Assert.equal(bundle.manifest.startMenu.slots[10].x, 128)
  local assetCount = 0
  for _ in pairs(bundle.assets) do
    assetCount = assetCount + 1
  end
  Assert.equal(assetCount, 6)
  for path, bytes in pairs(bundle.assets) do
    Assert.isTrue(path:find("^assets/generated/field/ui/") ~= nil)
    Assert.isTrue(#bytes > 0)
  end
  Assert.equal(bundle.marker, "field-ui-cache-v1:rom-sha:dependency-sha")
end

function T.compilation_is_deterministic()
  local romFs, sha1, hashLua = fixture()
  local a = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local b = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  Assert.equal(a.marker, b.marker)
  Assert.equal(LuaWriter.encode(a.manifest), LuaWriter.encode(b.manifest))
  for path, bytes in pairs(a.assets) do
    Assert.equal(bytes, b.assets[path])
  end
end

-- The manifest asset entries must describe the actual PNGs: pixel value v
-- maps to palette color v (the fixture's frame tiles carry value 1, which is
-- the fixture's second palette color 0x296B = (82,90,90), not the first
-- 0x7FFF = white), out-of-palette values are transparent, and every declared
-- atlas dimension matches the encoded image.
function T.atlas_pixels_and_dimensions_follow_the_source_mapping()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  for key, entry in pairs(bundle.manifest.assets) do
    local bytes = assert(bundle.assets[entry.image])
    local width, height = PngReader.rgba(bytes)
    Assert.equal(width, entry.width, key .. " width")
    Assert.equal(height, entry.height, key .. " height")
  end

  local frameWidth, _, frameRgba =
    PngReader.rgba(bundle.assets[bundle.manifest.assets["hgss.dialogue_frame.tiles"].image])
  local r, g, b, a = PngReader.pixel(frameRgba, frameWidth, 0, 0)
  Assert.equal(r, 82)
  Assert.equal(g, 90)
  Assert.equal(b, 90)
  Assert.equal(a, 255)
  -- Tile 1 carries value 2 and tile 14 value 15, which the two-color
  -- fixture palette cannot cover.
  local _, _, _, a2 = PngReader.pixel(frameRgba, frameWidth, 8, 0)
  Assert.equal(a2, 0)
  local _, _, _, a3 = PngReader.pixel(frameRgba, frameWidth, 14 * 8, 0)
  Assert.equal(a3, 0)

  -- The start menu background screen references palette bank 14, which the
  -- two-color fixture palette cannot cover: every pixel stays transparent.
  local bgWidth, _, bgRgba = PngReader.rgba(bundle.assets[bundle.manifest.assets["hgss.start_menu.background"].image])
  local _, _, _, bgA = PngReader.pixel(bgRgba, bgWidth, 10, 10)
  Assert.equal(bgA, 0)
end

function T.writer_commits_marker_last_and_reads_back()
  local romFs, sha1, hashLua = fixture()
  local bundle = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, bundle.marker))
  Assert.isFalse(FieldUiAssetCache.isReady(cache, bundle.marker .. "-stale"))
  local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()))
  Assert.equal(manifest.schema, FieldUiAssetCache.SCHEMA)
end

function T.failed_rebuild_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalWrite = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("start-menu.png", 1, true) then
      error("injected")
    end
    return originalWrite(self, path, data)
  end
  local second = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker, "no new marker leaked")
  Assert.isNil(backend:getInfo("staging/heartgold/field-ui"), "the stage is cleaned on failure")
  backend.write = originalWrite
  FieldUiCacheWriter.write(cache, second)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, second.marker), "a retry publishes the new class")
end

-- A stage-validation failure (the manifest fails strict validation after the
-- write) must surface as a typed failure and leave the previous class live.
function T.stage_validation_failure_is_typed_and_preserves_the_previous_class()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  FieldUiCacheWriter.write(cache, first)
  local second = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  second.manifest.startMenu.background.width = 999
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

-- A first publish rename failure (moving the live asset root aside) rolls
-- back and keeps the old class readable.
function T.first_publish_rename_failure_rolls_back()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  ---@diagnostic disable: duplicate-set-field
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 1 then
      error("injected rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

-- A second publish rename failure (moving the data root into place after the
-- asset root landed) must also roll back the first move.
function T.second_publish_rename_failure_rolls_back_both_roots()
  local romFs, sha1, hashLua = fixture()
  local first = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldUiCacheWriter.write(cache, first)
  local originalReplace = backend.replace
  local calls = 0
  ---@diagnostic disable: duplicate-set-field
  backend.replace = function(self, source, destination)
    calls = calls + 1
    if calls == 2 then
      error("injected second rename failure")
    end
    return originalReplace(self, source, destination)
  end
  local second = assert(FieldUiCompiler.compile(romFs, sha1, hashLua))
  second.marker = FieldUiAssetCache.marker(sha1, "new-dep-hash")
  Assert.throws(function()
    FieldUiCacheWriter.write(cache, second)
  end)
  backend.replace = originalReplace
  Assert.isTrue(FieldUiAssetCache.isReady(cache, first.marker), "the previous class remains ready after rollback")
  Assert.equal(cache:read(FieldUiAssetCache.markerPath()), first.marker)
end

function T.malformed_source_members_are_typed()
  local romFs, sha1, hashLua = fixture()
  romFs.openNarc = function(_, alias)
    local Narc = require("romdump.src.source.Narc")
    if alias == "start_menu" then
      -- A NARC whose background char member is not a G2D resource at all.
      local members = {}
      for i = 1, 65 do
        members[i] = string.rep("\0", 4)
      end
      members[13] = "not-a-g2d-resource"
      members[14] = romFs.read(romFs, 10)
      local data = romFs.read(romFs, 10)
      -- keep the other members from the real fixture narc by splicing: the
      -- simplest deterministic corruption is replacing member 12 only.
      local real = assert(Narc.open(data, "start_menu"))
      local junk = {}
      for id = 0, real:memberCount() - 1 do
        local bytes = real:readMember(id)
        if id == 12 then
          bytes = "junk-member"
        end
        junk[#junk + 1] = bytes
      end
      return assert(Narc.open(narc(junk), "start_menu"))
    end
    return assert(
      Narc.open(
        romFs.read(
          romFs,
          ({ start_menu = 10, dialogue_frames = 11, signpost_graphics = 12, trainer_card_graphics = 13 })[alias]
        ),
        alias
      )
    )
  end
  local bundle, err = FieldUiCompiler.compile(romFs, sha1, hashLua)
  Assert.isNil(bundle)
  Assert.isTrue(Errors.is(err))
end

return { tests = T }
