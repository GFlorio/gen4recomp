-- G2D container decoding contract: the byte-swapped "RGCN/RCSN/RECN/RNAN"
-- containers and their RAHC (char), NRCS (screen), TTLP/PLTT (palette), KBEC
-- (cell) and KNBA (animation) chunks. Fixtures are built by hand from the
-- GBATEK "Nitro Character Tiles / BG Maps Screens / OBJ Animations /
-- OBJ Metatile Cells" layouts; the real ROM gated the same layouts.

local Assert = require("tests.support.Assert")
local G2dDecoder = require("romdump.src.digest.G2dDecoder")

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

local function charBlock(tiles, depth)
  local payload = u16(8) .. u16(0x20) .. u32(depth) .. u16(0) .. u16(0) .. u32(0) .. u32(#tiles) .. u32(0x18) .. tiles
  return block("CHAR", payload)
end

local function screenBlock(entries, width, height)
  local body = {}
  for _, e in ipairs(entries) do
    body[#body + 1] = u16(e)
  end
  return block("SCRN", u16(width) .. u16(height) .. u32(0) .. u32(#entries * 2) .. table.concat(body))
end

local function paletteBlock(colors)
  local body = {}
  for _, c in ipairs(colors) do
    body[#body + 1] = u16(c)
  end
  -- PLTT: depth(1), unk(1), nColors(2), unk(4), dataOffset(4), colors
  return block("PLTT", string.char(3, 0) .. u16(#colors) .. u32(0) .. u32(12) .. table.concat(body))
end

-- Two 4bpp tiles: tile 0 all value 1, tile 1 all value 2.
local function twoTiles()
  return string.rep(string.char(0x11), 32) .. string.rep(string.char(0x22), 32)
end

function T.char_chunk_reports_depth_and_tiles()
  local data = container("RGCN", { charBlock(twoTiles(), 3) })
  local ch = assert(G2dDecoder.decodeChar(data))
  Assert.equal(ch.depth, 3)
  Assert.equal(#ch.tiles, 64)
end

function T.char_chunk_accepts_8bpp()
  local data = container("RGCN", { charBlock(string.rep("\1", 64), 4) })
  local ch = assert(G2dDecoder.decodeChar(data))
  Assert.equal(ch.depth, 4)
end

function T.screen_chunk_reports_size_and_entries()
  -- 16x8 pixels = 2x1 tiles: entry 0 = tile 3, entry 1 = tile 0x0400
  -- (flipH) | 0x0800 (flipV) | 5 << 12 (palette 5).
  local data = container("RCSN", { screenBlock({ 3, 0x0400 + 0x0800 + 5 * 4096 }, 16, 8) })
  local scr = assert(G2dDecoder.decodeScreen(data))
  Assert.equal(scr.width, 16)
  Assert.equal(scr.height, 8)
  Assert.equal(#scr.entries, 2)
  Assert.deepEqual(scr.entries[1], { tile = 3, flipH = false, flipV = false, palette = 0 })
  Assert.deepEqual(scr.entries[2], { tile = 0, flipH = true, flipV = true, palette = 5 })
end

function T.palette_chunk_decodes_15bit_colors()
  local data = container("NCLR", { paletteBlock({ 0x7FFF, 0x0000, 0x001F }) })
  local pal = assert(G2dDecoder.decodePalette(data))
  Assert.equal(#pal.colors, 3)
  Assert.deepEqual(pal.colors[1], { r = 255, g = 255, b = 255 })
  Assert.deepEqual(pal.colors[2], { r = 0, g = 0, b = 0 })
  Assert.deepEqual(pal.colors[3], { r = 0, g = 0, b = 255 })
end

-- KBEC: one metatile with two OBJs. Payload: numCells(2), entrySize(2),
-- metatileOffset(4) = 0x18, boundary(4), 12 zero bytes, then the metatile
-- table (8 bytes each) and the OBJ attribute table.
local function cellBlock(objs)
  local metatile = u16(#objs) .. u16(0) .. u32(0)
  local attr = {}
  for _, o in ipairs(objs) do
    attr[#attr + 1] = u16(o.y)
      .. u16(o.x)
      .. u16(o.tile + (o.flipH and 1024 or 0) + (o.flipV and 2048 or 0) + o.pal * 4096)
  end
  return block(
    "CEBK",
    u16(1) .. u16(0) .. u32(0x18) .. u32(0) .. string.rep("\0", 12) .. metatile .. table.concat(attr)
  )
end

function T.cell_chunk_reports_objs_per_cell()
  local data = container("RECN", {
    cellBlock({
      { x = 2, y = 3, tile = 7, flipH = false, flipV = false, pal = 0 },
      { x = -4, y = 5, tile = 9, flipH = true, flipV = false, pal = 1 },
    }),
  })
  local cell = assert(G2dDecoder.decodeCell(data))
  Assert.equal(#cell.cells, 1)
  Assert.equal(#cell.cells[1].objs, 2)
  Assert.deepEqual(cell.cells[1].objs[1], { x = 2, y = 3, tile = 7, flipH = false, flipV = false, palette = 0 })
  Assert.deepEqual(cell.cells[1].objs[2], { x = -4, y = 5, tile = 9, flipH = true, flipV = false, palette = 1 })
end

-- KNBA: one animation of two frames. Payload: numAnims(2), numFrames(2),
-- animsOffset(4) = 0x18, framesOffset(4), frameDataOffset(4), 8 zero bytes,
-- then 16-byte anim blocks, 8-byte frame blocks, and u16 frame data.
local function animBlock(frames)
  local anims = u16(1)
    .. u16(#frames)
    .. u32(0x18)
    .. u32(0x18 + 16)
    .. u32(0x18 + 16 + 8 * #frames)
    .. string.rep("\0", 8)
  local anim = u32(#frames) .. u16(0) .. u16(1) .. u32(1) .. u32(0)
  local frameBlocks = {}
  local frameData = {}
  for i, f in ipairs(frames) do
    frameBlocks[#frameBlocks + 1] = u32((i - 1) * 2) .. u16(f.duration) .. u16(0)
    frameData[#frameData + 1] = u16(f.cell)
  end
  return block("ABNK", anims .. anim .. table.concat(frameBlocks) .. table.concat(frameData))
end

function T.animation_chunk_reports_frames_with_durations()
  local data = container("RNAN", {
    animBlock({ { duration = 12, cell = 0 }, { duration = 3, cell = 1 } }),
  })
  local anim = assert(G2dDecoder.decodeAnimation(data))
  Assert.equal(#anim.anims, 1)
  Assert.equal(#anim.anims[1].frames, 2)
  Assert.deepEqual(anim.anims[1].frames[1], { cell = 0, duration = 12 })
  Assert.deepEqual(anim.anims[1].frames[2], { cell = 1, duration = 3 })
end

function T.bad_magic_and_truncated_chunks_are_typed()
  local out, err = G2dDecoder.decodeChar("not-a-g2d")
  Assert.isNil(out)
  Assert.equal(assert(err).code, "G2D_MAGIC_INVALID")
  -- A header declaring two blocks but carrying only one: the second block
  -- header extends past the declared size.
  local data = container("RGCN", { charBlock(twoTiles(), 3) })
  local broken = data:sub(1, 12) .. string.char(2, 0) .. data:sub(15)
  local out2, err2 = G2dDecoder.decodeScreen(broken)
  Assert.isNil(out2)
  Assert.equal(assert(err2).code, "G2D_BLOCK_INVALID")
end

function T.unknown_chunk_is_rejected()
  local data = container("RGCN", { block("SOPC", u32(0) .. u16(0x20) .. u16(8)) })
  local out, err = G2dDecoder.decodeChar(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, "G2D_CHUNK_MISSING")
end

return { tests = T }
