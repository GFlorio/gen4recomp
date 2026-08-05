-- Decoder for the DS geometry-engine display list embedded in an MDL0 shape.
-- The stream is in GX "packed" form: a u32 of four command bytes, then the
-- parameter words for those four commands in order (a 0x00 byte is a NOP with
-- no params). Command semantics follow GBATEK "DS Video Geometry Commands".
--
-- The decoder keeps persistent attribute state (position, normal, texcoord,
-- color) exactly as the hardware does -- partial vertex commands reuse the
-- previous coordinates -- and an internal 4x4 matrix stack so a self-contained
-- list transforms correctly. Node matrices selected via MTX_RESTORE default to
-- identity here; the model compiler supplies them through the SBC stream. DS
-- primitives are converted to indexed triangles. Unknown opcodes are fatal
-- with a byte offset. Pure domain module; arithmetic only.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local FixedPoint = require("libs.math.src.FixedPoint")

local GxDisplayList = {}

-- Per-vertex color provenance carried into the mesh (matches the G4M2 field):
-- 0 literal RGB (COLOR or a snapshotted diffuse), 1 produced by NORMAL lighting,
-- 2 sourced from the field-profile diffuse via the material's set-vertex-color.
local COLOR_SOURCE = { LITERAL = 0, NORMAL_LIT = 1, FIELD_DIFFUSE = 2 }

-- Parameter word count per opcode. Absent = unknown/unsupported (fatal).
local PARAM_WORDS = {
  [0x00] = 0, -- NOP
  [0x10] = 1, [0x11] = 0, [0x12] = 1, [0x13] = 1, [0x14] = 1, [0x15] = 0,
  [0x16] = 16, [0x17] = 12, [0x18] = 16, [0x19] = 12, [0x1A] = 9, [0x1B] = 3, [0x1C] = 3,
  [0x20] = 1, [0x21] = 1, [0x22] = 1, [0x23] = 2, [0x24] = 1, [0x25] = 1, [0x26] = 1,
  [0x27] = 1, [0x28] = 1, [0x29] = 1, [0x2A] = 1, [0x2B] = 1,
  [0x30] = 1, [0x31] = 1, [0x32] = 1, [0x33] = 1, [0x34] = 32,
  [0x40] = 1, [0x41] = 0,
}

local OPCODE_NAMES = {
  [0x10] = "MTX_MODE", [0x11] = "MTX_PUSH", [0x12] = "MTX_POP", [0x13] = "MTX_STORE",
  [0x14] = "MTX_RESTORE", [0x15] = "MTX_IDENTITY", [0x16] = "MTX_LOAD_4x4",
  [0x17] = "MTX_LOAD_4x3", [0x18] = "MTX_MULT_4x4", [0x19] = "MTX_MULT_4x3",
  [0x1A] = "MTX_MULT_3x3", [0x1B] = "MTX_SCALE", [0x1C] = "MTX_TRANS",
  [0x20] = "COLOR", [0x21] = "NORMAL", [0x22] = "TEXCOORD", [0x23] = "VTX_16",
  [0x24] = "VTX_10", [0x25] = "VTX_XY", [0x26] = "VTX_XZ", [0x27] = "VTX_YZ",
  [0x28] = "VTX_DIFF", [0x29] = "POLYGON_ATTR", [0x2A] = "TEXIMAGE_PARAM",
  [0x2B] = "PLTT_BASE", [0x30] = "DIF_AMB", [0x31] = "SPE_EMI", [0x32] = "LIGHT_VECTOR",
  [0x33] = "LIGHT_COLOR", [0x34] = "SHININESS", [0x40] = "BEGIN_VTXS", [0x41] = "END_VTXS",
}

-- ---- minimal column-major 4x4 matrix math (DS convention) ----

local function identity()
  return { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end

local function multiply(a, b) -- a * b, column-major
  local m = {}
  for col = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s = s + a[k * 4 + row + 1] * b[col * 4 + k + 1]
      end
      m[col * 4 + row + 1] = s
    end
  end
  return m
end

local function transformPoint(m, x, y, z)
  return m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
    m[3] * x + m[7] * y + m[11] * z + m[15]
end

-- 12 fx32 params (column-major 4x3) -> 4x4 with implicit (0,0,0,1) last row.
local function mat4x3(p)
  local f = FixedPoint.fx32
  return {
    f(p[1]), f(p[2]), f(p[3]), 0,
    f(p[4]), f(p[5]), f(p[6]), 0,
    f(p[7]), f(p[8]), f(p[9]), 0,
    f(p[10]), f(p[11]), f(p[12]), 1,
  }
end

local function mat4x4(p)
  local m = {}
  for i = 1, 16 do m[i] = FixedPoint.fx32(p[i]) end
  return m
end

-- ---- decoder state ----

local Decoder = {}
Decoder.__index = Decoder

local function newDecoder()
  return setmetatable({
    matrix = identity(),
    pushStack = {},
    restoreStack = {}, -- MTX_RESTORE slots, default identity
    pos = { 0, 0, 0 },
    normal = { 0, 1, 0 },
    uv = { 0, 0 },
    color = { 255, 255, 255 },
    colorSource = nil, -- resolved by COLOR/NORMAL or seeded from material state
    mtxMode = 0,
    run = nil, -- current BEGIN..END vertex-index buffer
    primType = nil,
    vertices = {},
    indices = {},
    opcodeCounts = {},
    polygonAttrs = {}, -- set of distinct POLYGON_ATTR words issued in-list
  }, Decoder)
end

function Decoder:restoreSlot(idx)
  return self.restoreStack[idx] or identity()
end

function Decoder:emitVertex()
  local wx, wy, wz = transformPoint(self.matrix, self.pos[1], self.pos[2], self.pos[3])
  self.vertices[#self.vertices + 1] = {
    x = wx, y = wy, z = wz,
    u = self.uv[1], v = self.uv[2],
    nx = self.normal[1], ny = self.normal[2], nz = self.normal[3],
    r = self.color[1], g = self.color[2], b = self.color[3], a = 255,
    colorSource = self.colorSource,
  }
  self.run[#self.run + 1] = #self.vertices - 1 -- zero-based index
end

local function s16(word) if word >= 0x8000 then return word - 0x10000 end return word end
local function s10(v) return FixedPoint.s10(v) end

-- Apply a matrix op to the position matrix; texture-matrix ops (mode 3) are
-- consumed but not applied, since they do not affect vertex bounds.
function Decoder:applyMatrix(m)
  if self.mtxMode == 3 then return end
  self.matrix = multiply(self.matrix, m)
end

local EXEC = {}

EXEC[0x10] = function(d, p) d.mtxMode = p[1] % 4 end
EXEC[0x11] = function(d) d.pushStack[#d.pushStack + 1] = d.matrix end
EXEC[0x12] = function(d)
  local m = d.pushStack[#d.pushStack]
  if m then d.matrix = m; d.pushStack[#d.pushStack] = nil end
end
EXEC[0x13] = function(d, p) d.restoreStack[p[1] % 32] = d.matrix end
EXEC[0x14] = function(d, p) d.matrix = d:restoreSlot(p[1] % 32) end
EXEC[0x15] = function(d) d.matrix = identity() end
EXEC[0x16] = function(d, p) if d.mtxMode ~= 3 then d.matrix = mat4x4(p) end end
EXEC[0x17] = function(d, p) if d.mtxMode ~= 3 then d.matrix = mat4x3(p) end end
EXEC[0x18] = function(d, p) d:applyMatrix(mat4x4(p)) end
EXEC[0x19] = function(d, p) d:applyMatrix(mat4x3(p)) end
EXEC[0x1A] = function(d, p)
  local f = FixedPoint.fx32
  d:applyMatrix({
    f(p[1]), f(p[2]), f(p[3]), 0, f(p[4]), f(p[5]), f(p[6]), 0,
    f(p[7]), f(p[8]), f(p[9]), 0, 0, 0, 0, 1,
  })
end
EXEC[0x1B] = function(d, p)
  local f = FixedPoint.fx32
  d:applyMatrix({ f(p[1]), 0, 0, 0, 0, f(p[2]), 0, 0, 0, 0, f(p[3]), 0, 0, 0, 0, 1 })
end
EXEC[0x1C] = function(d, p)
  local f = FixedPoint.fx32
  d:applyMatrix({ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, f(p[1]), f(p[2]), f(p[3]), 1 })
end

EXEC[0x20] = function(d, p) -- COLOR (BGR555) -> literal vertex color
  d.color = { FixedPoint.rgb555(p[1] % 0x8000) }
  d.colorSource = COLOR_SOURCE.LITERAL
end
EXEC[0x21] = function(d, p) -- NORMAL -> vertex color produced by lighting
  local nx, ny, nz = FixedPoint.normal10(p[1])
  d.normal = { nx, ny, nz }
  d.colorSource = COLOR_SOURCE.NORMAL_LIT
end
EXEC[0x22] = function(d, p) -- TEXCOORD (1.11.4 -> texel units)
  d.uv = { s16(p[1] % 0x10000) / 16, s16(math.floor(p[1] / 0x10000) % 0x10000) / 16 }
end
EXEC[0x23] = function(d, p) -- VTX_16 (fx16 1.3.12)
  d.pos = {
    s16(p[1] % 0x10000) / 4096,
    s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096,
    s16(p[2] % 0x10000) / 4096,
  }
  d:emitVertex()
end
EXEC[0x24] = function(d, p) -- VTX_10 (10-bit, high bits of 1.3.12 -> /64)
  local w = p[1]
  d.pos = { s10(w % 1024) / 64, s10(math.floor(w / 1024) % 1024) / 64, s10(math.floor(w / 1048576) % 1024) / 64 }
  d:emitVertex()
end
EXEC[0x25] = function(d, p) -- VTX_XY
  d.pos = { s16(p[1] % 0x10000) / 4096, s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096, d.pos[3] }
  d:emitVertex()
end
EXEC[0x26] = function(d, p) -- VTX_XZ
  d.pos = { s16(p[1] % 0x10000) / 4096, d.pos[2], s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096 }
  d:emitVertex()
end
EXEC[0x27] = function(d, p) -- VTX_YZ
  d.pos = { d.pos[1], s16(p[1] % 0x10000) / 4096, s16(math.floor(p[1] / 0x10000) % 0x10000) / 4096 }
  d:emitVertex()
end
EXEC[0x28] = function(d, p) -- VTX_DIFF (10-bit signed low bits of 1.3.12)
  local w = p[1]
  d.pos = {
    d.pos[1] + s10(w % 1024) / 4096,
    d.pos[2] + s10(math.floor(w / 1024) % 1024) / 4096,
    d.pos[3] + s10(math.floor(w / 1048576) % 1024) / 4096,
  }
  d:emitVertex()
end
EXEC[0x29] = function(d, p) d.polygonAttr = p[1]; d.polygonAttrs[p[1]] = true end
EXEC[0x2A] = function(d, p) d.texParam = p[1] end
EXEC[0x2B] = function(d, p) d.paletteBase = p[1] end
EXEC[0x30] = function() end
EXEC[0x31] = function() end
EXEC[0x32] = function() end
EXEC[0x33] = function() end
EXEC[0x34] = function() end

EXEC[0x40] = function(d, p) -- BEGIN_VTXS
  d.primType = p[1] % 4
  d.run = {}
end

local function convertRun(d, offset)
  local run, t = d.run, d.primType
  local n = #run
  local function tri(a, b, c)
    d.indices[#d.indices + 1] = run[a + 1]
    d.indices[#d.indices + 1] = run[b + 1]
    d.indices[#d.indices + 1] = run[c + 1]
  end
  if t == 0 then -- separate triangles
    if n % 3 ~= 0 then error(Errors.new("GX_INCOMPLETE_PRIMITIVE",
      string.format("triangle list has %d vertices (not a multiple of 3)", n), { offset = offset })) end
    for i = 0, n - 1, 3 do tri(i, i + 1, i + 2) end
  elseif t == 1 then -- separate quads
    if n % 4 ~= 0 then error(Errors.new("GX_INCOMPLETE_PRIMITIVE",
      string.format("quad list has %d vertices (not a multiple of 4)", n), { offset = offset })) end
    for i = 0, n - 1, 4 do tri(i, i + 1, i + 2); tri(i, i + 2, i + 3) end
  elseif t == 2 then -- triangle strip
    if n < 3 then error(Errors.new("GX_INCOMPLETE_PRIMITIVE",
      "triangle strip has fewer than 3 vertices", { offset = offset })) end
    for i = 2, n - 1 do
      if i % 2 == 0 then tri(i - 2, i - 1, i) else tri(i - 1, i - 2, i) end
    end
  elseif t == 3 then -- quad strip
    if n < 4 or n % 2 ~= 0 then error(Errors.new("GX_INCOMPLETE_PRIMITIVE",
      string.format("quad strip has %d vertices", n), { offset = offset })) end
    for i = 0, n - 4, 2 do tri(i, i + 1, i + 3); tri(i, i + 3, i + 2) end
  end
  d.run, d.primType = nil, nil
end

function GxDisplayList.opcodeName(op) return OPCODE_NAMES[op] end

GxDisplayList.COLOR_SOURCE = COLOR_SOURCE

local function _decode(bytes, options)
  options = options or {}
  local d = newDecoder()
  if options.restoreStack then d.restoreStack = options.restoreStack end
  if options.matrix then d.matrix = options.matrix end
  -- Seed the persistent color/normal/source state from the SBC draw's material
  -- (the geometry engine keeps this across a display-list call). Positions and
  -- matrices are not seeded: each shape decodes in model space as before.
  local seed = options.initialState
  if seed then
    if seed.color then d.color = { seed.color[1], seed.color[2], seed.color[3] } end
    if seed.normal then d.normal = { seed.normal[1], seed.normal[2], seed.normal[3] } end
    d.colorSource = seed.colorSource
  end
  local r = BinaryReader.new(bytes, "gx-dl")
  local len = #bytes
  local pos = 0
  local commands = {}

  while pos + 4 <= len do
    local cmdWord = r:u32le(pos)
    local cmdBytes = { cmdWord % 256, math.floor(cmdWord / 256) % 256,
      math.floor(cmdWord / 65536) % 256, math.floor(cmdWord / 16777216) % 256 }
    local cmdOffset = pos
    pos = pos + 4
    for i = 1, 4 do
      local op = cmdBytes[i]
      local n = PARAM_WORDS[op]
      if n == nil then
        error(Errors.new("GX_UNKNOWN_OPCODE",
          string.format("unknown geometry opcode 0x%02X at offset 0x%X", op, cmdOffset + i - 1),
          { opcode = op, offset = cmdOffset + i - 1, source = options.context }))
      end
      if op ~= 0x00 then
        local params = {}
        for k = 0, n - 1 do
          params[k + 1] = r:u32le(pos + k * 4)
        end
        pos = pos + n * 4
        commands[#commands + 1] = { opcode = op, offset = cmdOffset + i - 1 }
        d.opcodeCounts[op] = (d.opcodeCounts[op] or 0) + 1
        if op == 0x41 then
          convertRun(d, cmdOffset)
        else
          EXEC[op](d, params)
        end
      end
    end
  end

  if d.run then
    error(Errors.new("GX_UNTERMINATED_PRIMITIVE",
      "display list ended inside a BEGIN_VTXS block", { source = options.context }))
  end

  -- In the compile path every emitted vertex must carry a resolved color source;
  -- a nil source would otherwise render as an unintended default color.
  if options.requireColorSource then
    for i, v in ipairs(d.vertices) do
      if v.colorSource == nil then
        error(Errors.new("GX_UNRESOLVED_VERTEX_COLOR_SOURCE",
          string.format("vertex %d has no resolved color source (no COLOR/NORMAL and no material seed)", i - 1),
          { source = options.context }))
      end
    end
  end

  local bounds
  for _, v in ipairs(d.vertices) do
    if not bounds then
      bounds = { min = { v.x, v.y, v.z }, max = { v.x, v.y, v.z } }
    else
      bounds.min[1] = math.min(bounds.min[1], v.x); bounds.max[1] = math.max(bounds.max[1], v.x)
      bounds.min[2] = math.min(bounds.min[2], v.y); bounds.max[2] = math.max(bounds.max[2], v.y)
      bounds.min[3] = math.min(bounds.min[3], v.z); bounds.max[3] = math.max(bounds.max[3], v.z)
    end
  end

  local polygonAttrs = {}
  for word in pairs(d.polygonAttrs) do polygonAttrs[#polygonAttrs + 1] = word end
  table.sort(polygonAttrs)

  return {
    vertices = d.vertices,
    indices = d.indices,
    bounds = bounds,
    commands = commands,
    opcodeCounts = d.opcodeCounts,
    polygonAttrs = polygonAttrs,
    finalState = { color = d.color, normal = d.normal, colorSource = d.colorSource },
  }
end

function GxDisplayList.decode(bytes, options)
  local ok, result = pcall(_decode, bytes, options)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return GxDisplayList
