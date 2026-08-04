-- NSBMD / MDL0 decoder for static map and building models. Produces a
-- normalized, serializable inventory: per-model info counts, node/material/
-- shape names, texture/palette associations, the SBC draw-instance stream, and
-- per-shape geometry decoded through GxDisplayList (finite bounds + opcode
-- counts). Animation sections (NSBCA/NSBTA/...) are out of scope.
--
-- Layout (from pokeheartgold res_struct.h plus offsets verified against the
-- real HGSS Elm map model), all model-internal offsets relative to the model:
--   NNSG3dResMdl:  +0x00 size, +0x04 ofsSbc, +0x08 ofsMat, +0x0C ofsShp,
--                  +0x10 ofsEvpMtx, +0x14 info(0x2C), +0x40 node dict
--   Material blk:  +0x00 u16 ofsTexToMat, +0x02 u16 ofsPlttToMat, +0x04 dict
--   texToMat/plttToMat dict entry (4 bytes): u16 ofsList, u8 count, u8 bound;
--                  ofsList points at a u8[count] of material indices
--   Shape data:    +0x08 u32 ofsDL, +0x0C u32 sizeDL  (relative to shape data)
--   SBC:           packed byte stream, MAT(0x04)/SHP(0x05) form draw calls
-- Pure domain module.

local Errors = require("src.import.Errors")
local BinaryReader = require("src.import.BinaryReader")
local Fixed = require("src.data.nitro.Fixed")
local NitroFile = require("src.data.nitro.NitroFile")
local NitroDict = require("src.data.nitro.NitroDict")
local Nsbtx = require("src.data.nitro.Nsbtx")
local GxDisplayList = require("src.data.nitro.GxDisplayList")

local Nsbmd = {}

-- SBC opcode -> { name, argBytes(cmd) }. argBytes is the number of argument
-- bytes after the opcode; a function when it depends on the command's flag
-- bits (0x20/0x40/0x80 in the high bits). RET terminates the stream.
local function fixedArgs(n) return function() return n end end

local SBC = {
  [0x00] = { name = "NOP", args = fixedArgs(0) },
  [0x01] = { name = "RET", args = fixedArgs(0), terminates = true },
  [0x02] = { name = "NODE", args = fixedArgs(2) },
  [0x03] = { name = "MTX", args = fixedArgs(1) },
  [0x04] = { name = "MAT", args = fixedArgs(1) },
  [0x05] = { name = "SHP", args = fixedArgs(1) },
  [0x06] = { name = "NODEDESC", args = function(cmd)
    local n = 3
    if math.floor(cmd / 0x40) % 2 == 1 then n = n + 1 end
    if math.floor(cmd / 0x80) % 2 == 1 then n = n + 1 end
    return n
  end },
  [0x07] = { name = "BB", args = fixedArgs(2) },
  [0x08] = { name = "BBY", args = fixedArgs(2) },
  [0x09] = { name = "NODEMIX", args = fixedArgs(0) }, -- variable; unused by targets
  [0x0A] = { name = "CALLDL", args = fixedArgs(4) },
  [0x0B] = { name = "POSSCALE", args = fixedArgs(0) },
  [0x0C] = { name = "ENVMAP", args = fixedArgs(2) },
  [0x0D] = { name = "PRJMAP", args = fixedArgs(2) },
}

-- Decode the SBC stream in [start, limit). Returns commands, opcode counts, and
-- the ordered MAT/SHP draw instances bound to the active node.
local function decodeSbc(r, start, limit, context)
  local commands, counts, draws = {}, {}, {}
  local pos = start
  local currentNode, currentMaterial = 0, 0
  while pos < limit do
    local cmd = r:u8(pos)
    local op = cmd % 0x20 -- low 5 bits; high bits are option flags
    local def = SBC[op]
    if not def then
      error(Errors.new("SBC_UNKNOWN_OPCODE",
        string.format("unknown SBC opcode 0x%02X at offset 0x%X", cmd, pos),
        { opcode = cmd, offset = pos, source = context }))
    end
    local nargs = def.args(cmd)
    r:assertRange(pos, 1 + nargs, "sbc-cmd")
    commands[#commands + 1] = { opcode = op, command = cmd, offset = pos, name = def.name }
    counts[op] = (counts[op] or 0) + 1
    if op == 0x02 or op == 0x06 then
      currentNode = r:u8(pos + 1)
    elseif op == 0x04 then
      currentMaterial = r:u8(pos + 1)
    elseif op == 0x05 then
      draws[#draws + 1] = {
        nodeIndex = currentNode,
        materialIndex = currentMaterial,
        shapeIndex = r:u8(pos + 1),
        offset = pos,
      }
    end
    pos = pos + 1 + nargs
    if def.terminates then break end
  end
  return { commands = commands, opcodeCounts = counts, draws = draws }
end

local function decodeInfo(r, base)
  return {
    sbcType = r:u8(base + 0x00),
    scalingRule = r:u8(base + 0x01),
    numNode = r:u8(base + 0x03),
    numMat = r:u8(base + 0x04),
    numShp = r:u8(base + 0x05),
    posScale = Fixed.fx32(r:u32le(base + 0x08)),
    numVertex = r:u16le(base + 0x10),
    numPolygon = r:u16le(base + 0x12),
    numTriangle = r:u16le(base + 0x14),
    numQuad = r:u16le(base + 0x16),
    box = {
      x = Fixed.fx16(r:u16le(base + 0x18)),
      y = Fixed.fx16(r:u16le(base + 0x1A)),
      z = Fixed.fx16(r:u16le(base + 0x1C)),
      w = Fixed.fx16(r:u16le(base + 0x1E)),
      h = Fixed.fx16(r:u16le(base + 0x20)),
      d = Fixed.fx16(r:u16le(base + 0x22)),
    },
  }
end

local function bit(v, i) return math.floor(v / 2 ^ i) % 2 == 1 end

-- Effective bit after NitroSystem's global/material resolution: the material
-- value applies only where it owns the bit (mask set); elsewhere the global
-- default governs, which for a standalone compile with no global override is 0.
local function ownedBit(value, mask, i) return bit(mask, i) and bit(value, i) end

-- Parse the fixed NNSG3dResMatData prefix (res_struct.h) at matBase+blockOfs.
-- We keep texImageParam (the authoritative wrap/flip source the DS programs per
-- material) plus the fields needed to cross-check the block was located right.
local function decodeMaterialData(r, matBase, blockOfs)
  local base = matBase + blockOfs
  local texImageParam = r:u32le(base + 0x14)
  local texImageParamMask = r:u32le(base + 0x18)
  return {
    texImageParam = texImageParam,
    texImageParamMask = texImageParamMask,
    origWidth = r:u16le(base + 0x20),
    origHeight = r:u16le(base + 0x22),
    repeatX = ownedBit(texImageParam, texImageParamMask, 16),
    repeatY = ownedBit(texImageParam, texImageParamMask, 17),
    flipX = ownedBit(texImageParam, texImageParamMask, 18),
    flipY = ownedBit(texImageParam, texImageParamMask, 19),
  }
end

-- Read a name->materialIndices mapping dict (texToMat / plttToMat).
local function decodeMatBindings(r, sec, matBase, dictOffset, context)
  local dict = assert(NitroDict.decode(sec, matBase + dictOffset, context))
  local list = {}
  for _, e in ipairs(dict.entries) do
    local br = BinaryReader.new(e.data, "matbind")
    local ofsList = br:u16le(0)
    local count = br:u8(2)
    local materials = {}
    for i = 0, count - 1 do materials[#materials + 1] = r:u8(matBase + ofsList + i) end
    list[#list + 1] = { name = e.name, materials = materials }
  end
  return list
end

local function decodeModel(sec, modelBase, name, index, context)
  local r = BinaryReader.new(sec, "mdl0")
  local ofsSbc = r:u32le(modelBase + 0x04)
  local ofsMat = r:u32le(modelBase + 0x08)
  local ofsShp = r:u32le(modelBase + 0x0C)
  local info = decodeInfo(r, modelBase + 0x14)

  -- Nodes.
  local nodeDict = assert(NitroDict.decode(sec, modelBase + 0x40, context))
  local nodes = {}
  for _, e in ipairs(nodeDict.entries) do nodes[#nodes + 1] = { index = e.index, name = e.name } end

  -- Materials + texture/palette associations.
  local matBase = modelBase + ofsMat
  local ofsTexToMat = r:u16le(matBase)
  local ofsPlttToMat = r:u16le(matBase + 2)
  local matDict = assert(NitroDict.decode(sec, matBase + 4, context))
  local materials = {}
  for _, e in ipairs(matDict.entries) do
    -- The material dict payload is a u16 offset (from matBase) to the material's
    -- NNSG3dResMatData block.
    local m = decodeMaterialData(r, matBase, BinaryReader.new(e.data, "matref"):u16le(0))
    m.index = e.index
    m.name = e.name
    materials[e.index] = m
  end
  local textureAssociations = decodeMatBindings(r, sec, matBase, ofsTexToMat, context)
  local paletteAssociations = decodeMatBindings(r, sec, matBase, ofsPlttToMat, context)
  for _, assoc in ipairs(textureAssociations) do
    for _, mi in ipairs(assoc.materials) do
      if materials[mi] then materials[mi].textureName = assoc.name end
    end
  end
  for _, assoc in ipairs(paletteAssociations) do
    for _, mi in ipairs(assoc.materials) do
      if materials[mi] then materials[mi].paletteName = assoc.name end
    end
  end
  local materialList = {}
  for i = 0, info.numMat - 1 do materialList[#materialList + 1] = materials[i] end

  -- Shapes + geometry.
  local shpBase = modelBase + ofsShp
  local shpDict = assert(NitroDict.decode(sec, shpBase, context))
  local shapes = {}
  local modelBounds
  for _, e in ipairs(shpDict.entries) do
    local shpDataOffset = shpBase + BinaryReader.new(e.data, "shp"):u32le(0)
    local ofsDL = r:u32le(shpDataOffset + 0x08)
    local sizeDL = r:u32le(shpDataOffset + 0x0C)
    local dlOffset = shpDataOffset + ofsDL
    local dlBytes = r:bytes(dlOffset, sizeDL)
    local geometry, gerr = GxDisplayList.decode(dlBytes,
      { context = { model = name, shape = e.name } })
    if not geometry then error(gerr) end
    shapes[#shapes + 1] = {
      index = e.index,
      name = e.name,
      dlOffset = dlOffset,
      dlSize = sizeDL,
      vertexCount = #geometry.vertices,
      triangleCount = #geometry.indices / 3,
      bounds = geometry.bounds,
      opcodeCounts = geometry.opcodeCounts,
      geometry = geometry,
    }
    local b = geometry.bounds
    if b then
      if not modelBounds then
        modelBounds = { min = { b.min[1], b.min[2], b.min[3] }, max = { b.max[1], b.max[2], b.max[3] } }
      else
        for k = 1, 3 do
          modelBounds.min[k] = math.min(modelBounds.min[k], b.min[k])
          modelBounds.max[k] = math.max(modelBounds.max[k], b.max[k])
        end
      end
    end
  end

  local sbc = decodeSbc(r, modelBase + ofsSbc, modelBase + ofsMat, context)

  return {
    index = index,
    name = name,
    info = info,
    nodes = nodes,
    materials = materialList,
    shapes = shapes,
    textureAssociations = textureAssociations,
    paletteAssociations = paletteAssociations,
    sbc = sbc,
    bounds = modelBounds,
  }
end

local function _decode(bytes, context)
  local file, err = NitroFile.decode(bytes, "BMD0", context)
  if not file then error(err) end
  local mdlSection = NitroFile.section(file, "MDL0")
  if not mdlSection then
    error(Errors.new("NSBMD_NO_MDL0", "BMD0 file has no MDL0 section", { source = context }))
  end

  local sec = mdlSection.bytes
  local modelDict = assert(NitroDict.decode(sec, 8, context))
  local models = {}
  for _, e in ipairs(modelDict.entries) do
    local modelBase = BinaryReader.new(e.data, "mdlset"):u32le(0)
    models[#models + 1] = decodeModel(sec, modelBase, e.name, e.index, context)
  end

  local embeddedTextures
  local texSection = NitroFile.section(file, "TEX0")
  if texSection then
    embeddedTextures = assert(Nsbtx.decodeTex0(texSection.bytes, context))
  end

  local unknownSections = {}
  for _, s in ipairs(file.sections) do
    if s.magic ~= "MDL0" and s.magic ~= "TEX0" then
      unknownSections[#unknownSections + 1] = { magic = s.magic, offset = s.offset, size = s.size }
    end
  end

  return {
    models = models,
    embeddedTextures = embeddedTextures,
    unknownSections = unknownSections,
    source = context,
  }
end

function Nsbmd.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return Nsbmd
