-- Assembles a minimal but structurally real BMD0: one model, one node, one
-- material, one shape with a one-triangle display list, and an SBC draw stream.
-- Every part a test needs to vary is an option: the material's texture/palette
-- names (or no named bindings at all), the bounding box, the node transform,
-- and an optional embedded TEX0 section. Byte layouts match NNSG3dResMdl /
-- NNSG3dResMatData so the real Nsbmd decoder consumes it. Test-only.

local NB = require("tests.support.NitroBuilder")

local NsbmdFixture = {}

local u32 = NB.u32

local function fx16(v)
  return math.floor(v * 4096) % 0x10000
end

-- One-triangle display list (BEGIN triangles, 3x VTX_16, END) over three
-- { x, y, z } vertices.
local function triangleDL(verts)
  local function vtx16(v)
    return NB.u32(fx16(v[1]) + fx16(v[2]) * 0x10000) .. NB.u32(fx16(v[3]))
  end
  -- command group 1: 0x40 BEGIN, 0x23,0x23,0x23; group 2: 0x41 END, NOP,NOP,NOP
  return string.char(0x40, 0x23, 0x23, 0x23)
    .. NB.u32(0)
    .. vtx16(verts[1])
    .. vtx16(verts[2])
    .. vtx16(verts[3])
    .. string.char(0x41, 0, 0, 0)
end

-- A textured, normal-lit quad display list: BEGIN(quad list), then NORMAL,
-- TEXCOORD, VTX_16 per vertex, END. `verts` are four { x, y, z } in model units
-- and `uvs` four { s, t } in texel units, matching the field-actor billboard
-- shape. Commands are packed in groups of four with their parameters following,
-- as the DS geometry FIFO requires.
local function quadDL(verts, uvs)
  local function normal10(nx, ny, nz)
    local function c(v)
      return math.floor(v * 511) % 1024
    end
    return NB.u32(c(nx) + c(ny) * 1024 + c(nz) * 1048576)
  end
  local function texcoord(uv)
    return NB.u32((math.floor(uv[1] * 16) % 0x10000) + (math.floor(uv[2] * 16) % 0x10000) * 0x10000)
  end
  local function vtx16(v)
    return NB.u32(fx16(v[1]) + fx16(v[2]) * 0x10000) .. NB.u32(fx16(v[3]))
  end

  local ops, params = { 0x40 }, { NB.u32(1) } -- BEGIN_VTXS, primitive type 1 (quads)
  for i = 1, 4 do
    ops[#ops + 1], params[#params + 1] = 0x21, normal10(0, 0, 1)
    ops[#ops + 1], params[#params + 1] = 0x22, texcoord(uvs[i])
    ops[#ops + 1], params[#params + 1] = 0x23, vtx16(verts[i])
  end
  ops[#ops + 1], params[#params + 1] = 0x41, "" -- END_VTXS takes no parameter
  while #ops % 4 ~= 0 do
    ops[#ops + 1], params[#params + 1] = 0x00, "" -- NOP padding
  end

  local out = {}
  for group = 0, #ops / 4 - 1 do
    local bytes = {}
    for slot = 1, 4 do
      bytes[slot] = string.char(ops[group * 4 + slot])
    end
    out[#out + 1] = table.concat(bytes)
    for slot = 1, 4 do
      out[#out + 1] = params[group * 4 + slot]
    end
  end
  return table.concat(out)
end

-- NNSG3dResMatData prefix (0x2C bytes), distinct value in every field.
--   diffAmb : diffuse rgb555(31,0,0)=0x1F, set-vertex-color bit15, ambient
--             rgb555(0,31,0)=0x3E0
--   specEmi : specular rgb555(0,0,31)=0x7C00, emission rgb555(15,15,15)=0x3DEF
--   polyAttr: opts.polyAttr, default 0x001F00C1 (lightMask 1, front and back
--             render, alpha 31), always fully masked
--   flags   : diffuse+vertexColor ownership (0x40 | 0x100 = 0x140)
--   texImageParam at 0x14 requests repeat S/T (bits 16-17), full mask;
--   origWidth/Height at 0x20/0x22 come from the caller; magW/magH fx32 1.0 at
--   0x24/0x28.
local function materialData(origWidth, origHeight, polyAttr)
  local diffAmb = 0x1F + 0x8000 + 0x03E0 * 0x10000
  local specEmi = 0x7C00 + 0x3DEF * 0x10000
  return NB.u16(0)
    .. NB.u16(0x2C)
    .. NB.u32(diffAmb)
    .. NB.u32(specEmi)
    .. NB.u32(polyAttr or 0x001F00C1)
    .. NB.u32(0xFFFFFFFF)
    .. NB.u32(0x30000)
    .. NB.u32(0xFFFFFFFF)
    .. NB.u16(0)
    .. NB.u16(0x140)
    .. NB.u16(origWidth)
    .. NB.u16(origHeight)
    .. NB.u32(0x1000)
    .. NB.u32(0x1000)
end

-- texToMat / plttToMat entry: u16 ofsList, u8 count, u8 bound. The lists are
-- u8 material indices placed after the dicts in the same material block.
local function bindingEntry(ofsList)
  return NB.u16(ofsList) .. string.char(1, 0)
end

-- Material block holding one material named `materialName`, optionally bound to
-- one texture name and one palette name.
local function buildMaterialBlock(opts, materialName, textureName, paletteName)
  local matData = materialData(opts.origWidth or 8, opts.origHeight or 16, opts.polyAttr)
  local hasBindings = textureName ~= nil

  local matDict0 = NB.dict({ { name = materialName, data = u32(0) } })
  local texEntries = hasBindings and { { name = textureName, data = bindingEntry(0) } } or {}
  local pltEntries = hasBindings and { { name = paletteName, data = bindingEntry(0) } } or {}
  local texDict0 = NB.dict(texEntries)
  local pltDict0 = NB.dict(pltEntries)
  local lists = hasBindings and string.char(0, 0) or ""
  local listBase = 4 + #matDict0 + #texDict0 + #pltDict0 + 2

  local texDict = hasBindings and NB.dict({ { name = textureName, data = bindingEntry(listBase) } }) or texDict0
  local pltDict = hasBindings and NB.dict({ { name = paletteName, data = bindingEntry(listBase + 1) } }) or pltDict0
  local ofsMatData = 4 + #matDict0 + #texDict + #pltDict + #lists
  local matDict = NB.dict({ { name = materialName, data = NB.u16(ofsMatData) .. NB.u16(0) } })

  return NB.u16(4 + #matDict) .. NB.u16(4 + #matDict + #texDict) .. matDict .. texDict .. pltDict .. lists .. matData
end

local function buildShapeBlock(dl)
  local shpDict0 = NB.dict({ { name = "shp0", data = u32(0) } })
  local shapeDataOffset = #shpDict0
  local shapeData = u32(0) .. u32(0) .. u32(16) .. u32(#dl) -- flags, flags, ofsDL=16, sizeDL
  local shpDict = NB.dict({ { name = "shp0", data = u32(shapeDataOffset) } })
  return shpDict .. shapeData .. dl
end

-- The bounding box mirrors the triangle's own extents, so a fixture whose
-- geometry spans X and Z also reports the positive planar extent the map
-- compiler's calibration check requires.
local function buildInfo(verts, opts)
  local min, max = { 0, 0, 0 }, { 0, 0, 0 }
  for axis = 1, 3 do
    min[axis], max[axis] = verts[1][axis], verts[1][axis]
    for _, v in ipairs(verts) do
      min[axis] = math.min(min[axis], v[axis])
      max[axis] = math.max(max[axis], v[axis])
    end
  end
  local fields = {}
  fields[#fields + 1] = NB.u8(0) -- sbcType
  fields[#fields + 1] = NB.u8(0) -- scalingRule
  fields[#fields + 1] = NB.u8(0) -- texMtxMode
  fields[#fields + 1] = NB.u8(1) -- numNode
  fields[#fields + 1] = NB.u8(1) -- numMat
  fields[#fields + 1] = NB.u8(1) -- numShp
  fields[#fields + 1] = NB.u8(0) -- firstUnusedMtxStackID
  fields[#fields + 1] = NB.u8(0) -- dummy
  -- The default pair is deliberately not reciprocal, so a decoder reading one
  -- field at the other's offset is visible. opts.posScale sets both consistently.
  fields[#fields + 1] = NB.u32(0x1000 * (opts.posScale or 1)) -- posScale
  fields[#fields + 1] = NB.u32(opts.posScale and math.floor(0x1000 / opts.posScale) or 0x2000)
  fields[#fields + 1] = NB.u16(#verts) -- numVertex
  fields[#fields + 1] = NB.u16(1) -- numPolygon
  fields[#fields + 1] = NB.u16(1) -- numTriangle
  fields[#fields + 1] = NB.u16(0) -- numQuad
  for axis = 1, 3 do
    fields[#fields + 1] = NB.u16(fx16(min[axis]))
  end
  for axis = 1, 3 do
    fields[#fields + 1] = NB.u16(fx16(max[axis] - min[axis]))
  end
  fields[#fields + 1] = NB.u32(0x4000) -- boxPosScale
  fields[#fields + 1] = NB.u32(0x0800) -- boxInvPosScale
  return table.concat(fields)
end

-- Model layout: header(0x14) + info(0x2C) + nodeDict + nodeData + sbc + matBlock + shpBlock.
local function buildModel(opts, nodeDict, nodeData, sbc)
  local matBlock = buildMaterialBlock(
    opts,
    opts.materialName or "mat0",
    not opts.untextured and (opts.textureName or NsbmdFixture.TEXTURE_NAME) or nil,
    opts.paletteName or NsbmdFixture.PALETTE_NAME
  )
  local verts, dl
  if opts.quad then
    verts, dl = opts.quad.verts, quadDL(opts.quad.verts, opts.quad.uvs)
  else
    verts = opts.triangle or { { 0, 0, 0 }, { 2, 0, 0 }, { 0, 3, 0 } }
    dl = triangleDL(verts)
  end
  local shpBlock = buildShapeBlock(dl)
  local info = buildInfo(verts, opts)

  local ofsSbc = 0x40 + #nodeDict + #nodeData
  local ofsMat = ofsSbc + #sbc
  local ofsShp = ofsMat + #matBlock

  local body = string.rep("\0", 0x14) .. info .. nodeDict .. nodeData .. sbc .. matBlock .. shpBlock
  return u32(#body) .. NB.u32(ofsSbc) .. NB.u32(ofsMat) .. NB.u32(ofsShp) .. NB.u32(0) .. body:sub(0x15) -- replace the zeroed header region with real offsets
end

local function buildModelDict(modelName, model)
  local modelDict0 = NB.dict({ { name = modelName, data = u32(0) } })
  local modelOffset = 8 + #modelDict0
  local modelDict = NB.dict({ { name = modelName, data = u32(modelOffset) } })
  return modelDict .. model
end

local function nodeDictFor(name)
  local nodeDict0 = NB.dict({ { name = name, data = u32(0) } })
  return NB.dict({ { name = name, data = u32(#nodeDict0) } })
end

local function file(opts, nodeDict, nodeData, sbc)
  local sections =
    { { magic = "MDL0", body = buildModelDict(opts.modelName or "m0", buildModel(opts, nodeDict, nodeData, sbc)) } }
  if opts.embeddedTex0 then
    -- NitroBuilder.file re-emits the 8-byte block header, so strip the one the
    -- TEX0 fixture already wrote.
    sections[#sections + 1] = { magic = "TEX0", body = opts.embeddedTex0:sub(9) }
  end
  return NB.file("BMD0", sections)
end

-- NODEDESC(root), NODE(0,vis), POSSCALE, MAT/SHP, RET.
local SBC_ONE_DRAW = string.char(0x06, 0, 0, 0) -- NODEDESC node0 parent0 flags0
  .. string.char(0x02, 0, 1) -- NODE node0 vis1
  .. string.char(0x0B) -- POSSCALE (normal)
  .. string.char(0x04, 0) -- MAT 0
  .. string.char(0x05, 0) -- SHP 0
  .. string.char(0x01) -- RET

-- The same stream with a second MAT/SHP pair after the inverse POSSCALE, so
-- tests see two draw instances of one shape.
local SBC_TWO_DRAWS = SBC_ONE_DRAW:sub(1, -2)
  .. string.char(0x2B) -- POSSCALE (inverse)
  .. string.char(0x04, 0)
  .. string.char(0x05, 0)
  .. string.char(0x01)

-- opts (all optional):
--   modelName / materialName  default "m0" / "mat0"
--   textureName, paletteName  named material bindings, default "tex0" / "pal0"
--   untextured                true for a model with no named texture bindings
--   origWidth, origHeight     the material's stored texture size, default 8x16;
--                             must match the bound texture or the compiler
--                             asserts a bad parse offset
--   triangle                  three { x, y, z } vertices, default
--                             (0,0,0) (2,0,0) (0,3,0); use a triangle spanning
--                             X and Z for models the map compiler calibrates
--   embeddedTex0              a Tex0Fixture.block to attach as a TEX0 section
function NsbmdFixture.build(opts)
  -- Identity node: flags = TRANS_ZERO | ROT_ZERO | SCALE_ONE, _00 = 0.
  local nodeData = NB.u16(0x0007) .. NB.u16(0)
  return file(opts or {}, nodeDictFor("root"), nodeData, SBC_TWO_DRAWS)
end

-- The same model with its node translated (2,0,0), identity rotation, scale
-- (2,1,1), and a single MAT/SHP draw.
function NsbmdFixture.buildTransformed(opts)
  local nodeData = NB.u16(0x0000)
    .. NB.u16(0x1000) -- flags=0, _00=1.0
    .. NB.u32(0x2000)
    .. NB.u32(0)
    .. NB.u32(0) -- translation
    .. NB.u16(0)
    .. NB.u16(0)
    .. NB.u16(0) -- rotation col0 rows 1,2 + col1 row0
    .. NB.u16(0x1000)
    .. NB.u16(0)
    .. NB.u16(0) -- col1 row1, row2 + col2 row0
    .. NB.u16(0)
    .. NB.u16(0x1000) -- col2 row1, row2
    .. NB.u32(0x2000)
    .. NB.u32(0x1000)
    .. NB.u32(0x1000) -- scale
  return file(opts or {}, nodeDictFor("root"), nodeData, SBC_ONE_DRAW)
end

-- NODEDESC(root), BB(node0), POSSCALE, MAT/SHP, RET: the field-actor shape, whose
-- one quad is drawn as a Nitro full camera-facing billboard.
local SBC_BILLBOARD_DRAW = string.char(0x06, 0, 0, 0)
  .. string.char(0x07, 0) -- BB node0
  .. string.char(0x0B)
  .. string.char(0x04, 0)
  .. string.char(0x05, 0)
  .. string.char(0x01)

local SBC_STATIC_QUAD_DRAW = string.char(0x06, 0, 0, 0)
  .. string.char(0x0B)
  .. string.char(0x04, 0)
  .. string.char(0x05, 0)
  .. string.char(0x01)

-- A bottom-centered textured quad drawn as a billboard, the shared field-actor
-- model's shape. `opts.size` is the model-unit extent (default 32, i.e. two
-- runtime tiles at the fixture's posScale of 8) and `opts.uvSize` the texel
-- extent of its UVs (default 32). Its material defaults to the actor polygon
-- state (single-sided, fogged, opaque polygon alpha, polygon id 0). Other opts
-- pass through to NsbmdFixture.build.
function NsbmdFixture.buildBillboardQuad(opts)
  opts = opts or {}
  local posScale = opts.posScale or 8
  local size = (opts.size or 32) / posScale
  local uv = opts.uvSize or 32
  local merged = {
    posScale = posScale,
    polyAttr = opts.polyAttr or 0x001F8081,
    quad = {
      verts = { { -size / 2, 0, 0 }, { size / 2, 0, 0 }, { size / 2, size, 0 }, { -size / 2, size, 0 } },
      uvs = { { 0, uv }, { uv, uv }, { uv, 0 }, { 0, 0 } },
    },
  }
  for key, value in pairs(opts) do
    if key ~= "size" and key ~= "uvSize" and key ~= "posScale" then
      merged[key] = value
    end
  end
  local nodeData = NB.u16(0x0007) .. NB.u16(0)
  return file(merged, nodeDictFor("root"), nodeData, SBC_BILLBOARD_DRAW)
end

function NsbmdFixture.buildStaticQuad(opts)
  opts = opts or {}
  local posScale = opts.posScale or 8
  local size = (opts.size or 16) / posScale
  local uv = opts.uvSize or 8
  local merged = {
    posScale = posScale,
    polyAttr = opts.polyAttr or 0x001F00C1,
    quad = {
      verts = { { -size / 2, 0, 0 }, { size / 2, 0, 0 }, { size / 2, size, 0 }, { -size / 2, size, 0 } },
      uvs = { { 0, uv }, { uv, uv }, { uv, 0 }, { 0, 0 } },
    },
  }
  for key, value in pairs(opts) do
    if key ~= "size" and key ~= "uvSize" and key ~= "posScale" then
      merged[key] = value
    end
  end
  local nodeData = NB.u16(0x0007) .. NB.u16(0)
  return file(merged, nodeDictFor("root"), nodeData, SBC_STATIC_QUAD_DRAW)
end

-- The identity-node model with a caller-supplied SBC byte stream, so SBC decoder
-- tests can exercise operand forms the two canned streams do not cover.
function NsbmdFixture.buildWithSbc(sbc, opts)
  local nodeData = NB.u16(0x0007) .. NB.u16(0)
  return file(opts or {}, nodeDictFor("root"), nodeData, sbc)
end

-- A node dictionary entry storing offset 0, which the decoder must reject
-- rather than read node data from the dictionary itself.
function NsbmdFixture.buildZeroNodeDataOffset()
  return file({}, NB.dict({ { name = "root", data = u32(0) } }), "", SBC_ONE_DRAW)
end

-- Default material binding names, so callers can build a matching Tex0Fixture.
NsbmdFixture.TEXTURE_NAME = "tex0"
NsbmdFixture.PALETTE_NAME = "pal0"

return NsbmdFixture
