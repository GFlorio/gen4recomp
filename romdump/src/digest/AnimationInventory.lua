-- Read-only census of HGSS build-model animation resources: every member of the
-- shared animation archive (build_anim, a/1/0/6), both animation-list
-- archives (a/1/0/7 exterior, a/1/0/8 interior), and the transform features of
-- the associated build NSBMDs (scaling rule, texture-matrix mode, SBC commands,
-- NODEMIX, billboards, display-list matrix ops).
--
-- It exists to scope the animation sprint from evidence: the layout below was
-- verified against the actual HGSS ROM members, not assumed from the SDK.
-- Verified structure of an animation resource (NNSG3dResFileHeader + one anm
-- section):
--   file:  magic BCA0/BTA0/BTP0/BMA0/BVA0, version at +0x06, section table
--   section: 8-byte block header (magic JNT0/SRT0/PAT0/MAT0/VIS0 + u32 size),
--     then a standard NNSG3dResDict mapping the animation name to a u32 offset
--     (from the section start) of the per-format record:
--       +0x00 4 bytes format kind (raw: "J\0AC" / "M\0AT" / "M\0AM" / "M\0PT")
--       +0x04 u16 numFrame
--       JNT0: +0x06 u16 numAnm, +0x0C u32 ofsAnmData, +0x10 u32 ofsInvScale,
--             +0x14 u16 numInvScale, +0x18 u16 ofsTargets
--       SRT0/MAT0: +0x16 u16 numTargets
--       PAT0: +0x06 u8 numTextures, +0x07 u8 numPalettes, +0x08 u16 recordSize,
--             +0x20 u32 keyCount, +0x26 u16 ofsKeys (record-relative),
--             +0x28 16-byte model name, keys of (u16 frame, u8 texIdx,
--             u8 plttIdx) at ofsKeys, then the texture/palette names.
-- Per-target record semantics (JNT/SRT/MAT curve layouts) are NOT decoded here:
-- the pinned pokeheartgold decomp vendors only the binres headers, and the
-- per-target bytes could not be reliably named from the ROM alone. Those
-- regions are reported raw (targetsRaw, targetDataRaw) for Epic 1.
--
-- `inspectResource`/`inspectListRecord` are pure; `scan` walks a RomFs and is
-- the LÖVE-side entry point.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")
local NitroFile = require("romdump.src.digest.nitro.NitroFile")
local NitroDict = require("romdump.src.digest.nitro.NitroDict")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local GxDisplayList = require("romdump.src.digest.nitro.GxDisplayList")
local SbcInventory = require("romdump.src.digest.SbcInventory")
local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")

local AnimationInventory = {}

local NAME_SIZE = 16
local SECTION_MAGICS = {
  JNT0 = "NSBCA",
  SRT0 = "NSBTA",
  PAT0 = "NSBTP",
  MAT0 = "NSBMA",
  VIS0 = "NSBVA",
}

-- The 16-byte NUL-padded name at `at` inside `bytes`.
local function readName(bytes, at)
  if at < 0 or at + NAME_SIZE > #bytes then
    return nil
  end
  return (bytes:sub(at + 1, at + NAME_SIZE):gsub("%z.*$", ""))
end

local function hex4(bytes, at)
  local b = string.byte(bytes, at + 1)
  if not b then
    return nil
  end
  return string.format(
    "%02X%02X%02X%02X",
    b,
    string.byte(bytes, at + 2) or 0,
    string.byte(bytes, at + 3) or 0,
    string.byte(bytes, at + 4) or 0
  )
end

-- Decode the JNT0 (NSBCA) record. Record-level fields are verified against the
-- ROM; per-target bytes are preserved raw until Epic 1 pins the SDK layout.
local function inspectJnt(r, base, context)
  local numAnm = r:u16le(base + 0x06)
  local numInvScale = r:u16le(base + 0x14)
  local targets = {}
  for i = 0, numAnm - 1 do
    local at = base + 0x1C + i * 4
    local ok, bytes = pcall(r.bytes, r, at, 4)
    if not ok then
      break
    end
    targets[#targets + 1] = {
      index = i,
      raw = hex4(bytes, 0),
      nodeIndexRaw = r:u16le(at + 2),
    }
  end
  return {
    numFrame = r:u16le(base + 0x04),
    numAnm = numAnm,
    numInvScale = numInvScale,
    ofsAnmData = r:u32le(base + 0x0C),
    ofsInvScale = r:u32le(base + 0x10),
    targets = targets,
  }
end

-- Decode the SRT0 (NSBTA) record: numFrame, target count, and the raw
-- per-target data region (curve layout pending Epic 1 SDK pinning).
local function inspectSrt(r, base, context)
  local numTargets = r:u16le(base + 0x16)
  local targetStart = base + 0x1C
  return {
    numFrame = r:u16le(base + 0x04),
    numTargets = numTargets,
    targetsDataRaw = r:bytes(targetStart, math.min(numTargets * 8, 64)),
  }
end

-- Decode the MAT0 (NSBMA) record: numFrame, target count, the raw target data
-- block, and the bound material name at +0x30.
local function inspectMat(r, base, context)
  local numTargets = r:u16le(base + 0x16)
  if numTargets > 64 then
    numTargets = 0
  end
  local rawAt = base + 0x1C
  local rawLen = math.min(numTargets * 20, r:length() - rawAt)
  return {
    numFrame = r:u16le(base + 0x04),
    numTargets = numTargets,
    targetsDataRaw = rawLen > 0 and r:bytes(rawAt, rawLen) or "",
    targetName = readName(r:bytes(0, r:length()), base + 0x30),
  }
end

-- Decode the PAT0 (NSBTP) record fully: key list, texture/palette counts and
-- the referenced texture/palette names. Verified layout: numTargets (u8) at
-- +0x0D, a 4-byte per-target pre-record at +0x1C, one 8-byte key record per
-- target at +0x1C + numTargets*4 of (u32 keyCount)(u16 ??)(u16 ofsKeys), the
-- 16-byte target names at +0x1C + numTargets*12, the per-target key arrays at
-- record + ofsKeys, then numTextures texture names at +0x08 and numPalettes
-- palette names at +0x0A.
local function inspectPat(r, base, context)
  local numFrame = r:u16le(base + 0x04)
  local numTextures = r:u8(base + 0x06)
  local numPalettes = r:u8(base + 0x07)
  local numTargets = r:u8(base + 0x0D)
  local full = r:bytes(0, r:length())

  local keySets, names = {}, {}
  for i = 0, numTargets - 1 do
    local at = base + 0x1C + numTargets * 4 + i * 8
    r:assertRange(at, 8, "sbc-btp-target")
    local keyCount = r:u32le(at)
    local ofsKeys = r:u16le(at + 6)
    keySets[#keySets + 1] = { keyCount = keyCount, keysAt = base + ofsKeys }
    names[#names + 1] = readName(full, base + 0x1C + numTargets * 12 + i * NAME_SIZE)
  end

  local keys, maxTex, maxPltt = {}, -1, -1
  for _, ks in ipairs(keySets) do
    for i = 0, ks.keyCount - 1 do
      local at = ks.keysAt + i * 4
      r:assertRange(at, 4, "sbc-btp-key")
      local frame = r:u16le(at)
      local texIdx = r:u8(at + 2)
      local plttIdx = r:u8(at + 3)
      keys[#keys + 1] = { frame = frame, texIdx = texIdx, plttIdx = plttIdx }
      maxTex = math.max(maxTex, texIdx)
      maxPltt = math.max(maxPltt, plttIdx)
    end
  end

  -- The texture/palette names follow the record, numTextures + numPalettes of
  -- them, texture names first (verified against the ROM).
  local textures, palettes = {}, {}
  local nameAt = base + r:u16le(base + 0x08)
  for i = 0, numTextures - 1 do
    textures[#textures + 1] = readName(full, nameAt + i * NAME_SIZE)
  end
  local plAt = base + r:u16le(base + 0x0A)
  for i = 0, numPalettes - 1 do
    palettes[#palettes + 1] = readName(full, plAt + i * NAME_SIZE)
  end
  return {
    numFrame = numFrame,
    numTargets = numTargets,
    numTextures = numTextures,
    numPalettes = numPalettes,
    keyCount = #keys,
    maxTexIdx = maxTex,
    maxPlttIdx = maxPltt,
    keys = keys,
    targetNames = names,
    textureNames = textures,
    paletteNames = palettes,
  }
end

-- Decode one animation resource (a member of a/1/0/6). Returns a normalized
-- census record; raises a structured error on malformed data.
function AnimationInventory.inspectResource(bytes, context)
  assert(type(bytes) == "string", "AnimationInventory.inspectResource requires a string")
  local file, err = NitroFile.decode(bytes, nil, context)
  if not file then
    error(err)
  end
  local section = file.sections[1]
  if not section then
    Errors.raise("ANIM_NO_SECTION", string.format("%s file has no sections", file.magic), { source = context })
  end
  local format = SECTION_MAGICS[section.magic]
  if not format then
    Errors.raise(
      "ANIM_UNKNOWN_SECTION",
      string.format("%s file has unknown animation section %q", file.magic, section.magic),
      { magic = file.magic, section = section.magic, source = context }
    )
  end

  local r = BinaryReader.new(section.bytes, "anm-section")
  local dict = assert(NitroDict.decode(section.bytes, 8, context))
  local animations = {}
  for _, entry in ipairs(dict.entries) do
    local recordBase = BinaryReader.new(entry.data, "anm-record"):u32le(0)
    r:assertRange(recordBase, 0x1C, "anm-record-header")
    local kind = hex4(r:bytes(recordBase, 4), 0)
    local detail
    if section.magic == "JNT0" then
      detail = inspectJnt(r, recordBase, context)
    elseif section.magic == "SRT0" then
      detail = inspectSrt(r, recordBase, context)
    elseif section.magic == "MAT0" then
      detail = inspectMat(r, recordBase, context)
    elseif section.magic == "PAT0" then
      detail = inspectPat(r, recordBase, context)
    elseif section.magic == "VIS0" then
      detail = { numFrame = r:u16le(recordBase + 0x04) }
    end
    animations[#animations + 1] = {
      name = entry.name,
      recordOffset = recordBase,
      kindRaw = kind,
      detail = detail,
    }
  end

  return {
    fileMagic = file.magic,
    format = format,
    revision = file.version,
    section = section.magic,
    sectionSize = section.size,
    animations = animations,
    source = context,
  }
end

-- Decode one 0x18-byte animation-list record, preserving the first eight
-- metadata bytes losslessly (their semantics are not named until
-- demonstrated) and the resource-id array.
function AnimationInventory.inspectListRecord(bytes)
  assert(type(bytes) == "string", "AnimationInventory.inspectListRecord requires a string")
  local r = BinaryReader.new(bytes, "anim-list-record")
  local headerRaw = {}
  local flagsRaw = {}
  for i = 0, 3 do
    headerRaw[#headerRaw + 1] = r:u8(i)
  end
  for i = 4, 7 do
    flagsRaw[#flagsRaw + 1] = r:u8(i)
  end
  local ids = BuildModelAnimList.decode(bytes).ids
  local function hex(bytes)
    local out = {}
    for _, b in ipairs(bytes) do
      out[#out + 1] = string.format("%02X", b)
    end
    return table.concat(out, "")
  end
  return {
    headerRaw = hex(headerRaw),
    flagsRaw = hex(flagsRaw),
    ids = ids,
  }
end

-- ---- ROM walk ----

local function readMember(narc, memberId)
  return assert(narc:readMember(memberId))
end

local function walkResources(romFs)
  local narc = assert(romFs:openNarc("build_anim"))
  local resources, skipped = {}, {}
  for memberId = 0, narc:memberCount() - 1 do
    local ok, result = pcall(function()
      return AnimationInventory.inspectResource(
        readMember(narc, memberId),
        { alias = "build_anim", memberId = memberId }
      )
    end)
    if ok then
      result.memberId = memberId
      resources[#resources + 1] = result
    else
      skipped[#skipped + 1] = {
        archive = "build_anim",
        memberId = memberId,
        code = Errors.is(result) and result.code or "LUA_ERROR",
        message = Errors.is(result) and result.message or tostring(result),
      }
    end
  end
  return resources, skipped
end

local function walkLists(romFs, alias)
  local narc, err = romFs:openNarc(alias)
  if not narc then
    Errors.raise("ANIM_LIST_OPEN_FAILED", "could not open " .. alias .. ": " .. Errors.format(err), { alias = alias })
  end
  local records, skipped = {}, {}
  for memberId = 0, narc:memberCount() - 1 do
    local ok, result = pcall(function()
      local record = AnimationInventory.inspectListRecord(readMember(narc, memberId))
      record.memberId = memberId
      return record
    end)
    if ok then
      records[#records + 1] = result
    else
      skipped[#skipped + 1] = {
        archive = alias,
        memberId = memberId,
        code = Errors.is(result) and result.code or "LUA_ERROR",
        message = Errors.is(result) and result.message or tostring(result),
      }
    end
  end
  return records, skipped
end

-- The transform features of one build model: SbcInventory's command census plus
-- the texture-matrix mode and display-list matrix-op usage.
function AnimationInventory.inspectModel(model)
  local entry = SbcInventory.inspectModel(model)
  local gxMtx = {}
  for _, shp in ipairs(model.shapes) do
    for op, n in pairs(shp.opcodeCounts) do
      local name = GxDisplayList.opcodeName(op)
      if name and name:sub(1, 4) == "MTX_" then
        gxMtx[name] = (gxMtx[name] or 0) + n
      end
    end
  end
  entry.texMtxMode = model.info.texMtxMode
  entry.gxMtx = gxMtx
  return entry
end

-- Walk the three animation archives plus every build model. Returns
-- { resources, exteriorList, interiorList, models, skipped }.
function AnimationInventory.scan(romFs)
  local resources, skipped = walkResources(romFs)
  local exteriorList, extSkipped = walkLists(romFs, "exterior_build_anim_list")
  local interiorList, intSkipped = walkLists(romFs, "interior_build_anim_list")
  for _, s in ipairs(extSkipped) do
    skipped[#skipped + 1] = s
  end
  for _, s in ipairs(intSkipped) do
    skipped[#skipped + 1] = s
  end

  local models, modelSkipped = {}, {}
  local sources = {
    { alias = "exterior_build_models" },
    { alias = "interior_build_models" },
  }
  for _, source in ipairs(sources) do
    local narc = assert(romFs:openNarc(source.alias))
    for memberId = 0, narc:memberCount() - 1 do
      local ok, result = pcall(function()
        local file = assert(Nsbmd.decode(readMember(narc, memberId), { alias = source.alias, memberId = memberId }))
        return AnimationInventory.inspectModel(file.models[1])
      end)
      if ok then
        result.archive, result.memberId = source.alias, memberId
        models[#models + 1] = result
      else
        modelSkipped[#modelSkipped + 1] = {
          archive = source.alias,
          memberId = memberId,
          code = Errors.is(result) and result.code or "LUA_ERROR",
          message = Errors.is(result) and result.message or tostring(result),
        }
      end
    end
  end
  for _, s in ipairs(modelSkipped) do
    skipped[#skipped + 1] = s
  end

  return {
    resources = resources,
    exteriorList = exteriorList,
    interiorList = interiorList,
    models = models,
    skipped = skipped,
  }
end

-- ---- reporting ----

local function sortedKeys(map)
  local out = {}
  for k in pairs(map) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

local function identity(entry)
  return string.format("%s:%d", entry.archive, entry.memberId)
end

-- Deterministic, payload-free summary lines.
function AnimationInventory.lines(report)
  local L = {}
  local function add(fmt, ...)
    L[#L + 1] = string.format(fmt, ...)
  end

  local formatCounts, sectionCounts, frameCounts = {}, {}, {}
  local numAnmCounts = {}
  local targetDataNotes = {}

  for _, res in ipairs(report.resources) do
    local key = res.format
    formatCounts[key] = (formatCounts[key] or 0) + 1
    sectionCounts[res.section] = (sectionCounts[res.section] or 0) + 1
    for _, anm in ipairs(res.animations) do
      local d = anm.detail
      add(
        "anim-resource\t%d\t%s\t%s\t%s\t%s\t%s\tframe=%d",
        res.memberId,
        res.fileMagic,
        res.format,
        res.section,
        anm.name,
        anm.kindRaw,
        d and d.numFrame or -1
      )
      if res.format == "NSBCA" then
        add(
          "anim-jnt\t%d\t%s\ttargets=%d\tinvScale=%d\tofsAnm=0x%X\tofsInvScale=0x%X",
          res.memberId,
          anm.name,
          d.numAnm,
          d.numInvScale,
          d.ofsAnmData,
          d.ofsInvScale
        )
        for _, t in ipairs(d.targets) do
          add("anim-jnt-target\t%d\t%s\t%d\traw=%s\tnodeRaw=%d", res.memberId, anm.name, t.index, t.raw, t.nodeIndexRaw)
        end
      elseif res.format == "NSBTA" then
        add(
          "anim-srt\t%d\t%s\ttargets=%d\tdataRaw=%s",
          res.memberId,
          anm.name,
          d.numTargets,
          (
            d.targetsDataRaw:gsub(".", function(c)
              return string.format("%02X", string.byte(c))
            end)
          )
        )
      elseif res.format == "NSBMA" then
        add(
          "anim-mat\t%d\t%s\ttargets=%d\tmaterial=%s\tdataRaw=%s",
          res.memberId,
          anm.name,
          d.numTargets,
          tostring(d.targetName),
          (
            d.targetsDataRaw:gsub(".", function(c)
              return string.format("%02X", string.byte(c))
            end)
          )
        )
      elseif res.format == "NSBTP" then
        add(
          "anim-btp\t%d\t%s\ttex=%d\tpltt=%d\tkeys=%d\tmaxTex=%d\tmaxPltt=%d",
          res.memberId,
          anm.name,
          d.numTextures,
          d.numPalettes,
          d.keyCount,
          d.maxTexIdx,
          d.maxPlttIdx
        )
        add("anim-btp-textures\t%d\t%s\t%s", res.memberId, anm.name, table.concat(d.textureNames, ","))
        add("anim-btp-palettes\t%d\t%s\t%s", res.memberId, anm.name, table.concat(d.paletteNames, ","))
      end
    end
  end

  for _, record in ipairs(report.exteriorList) do
    add(
      "anim-list\texterior\t%d\theader=%s\tflags=%s\tids=%s",
      record.memberId,
      record.headerRaw,
      record.flagsRaw,
      table.concat(record.ids, ",")
    )
  end
  for _, record in ipairs(report.interiorList) do
    add(
      "anim-list\tinterior\t%d\theader=%s\tflags=%s\tids=%s",
      record.memberId,
      record.headerRaw,
      record.flagsRaw,
      table.concat(record.ids, ",")
    )
  end

  local resourceById = {}
  for _, res in ipairs(report.resources) do
    local first = res.animations[1]
    resourceById[res.memberId] = {
      magic = res.fileMagic,
      format = res.format,
      name = first and first.name or nil,
      numFrame = first and first.detail and first.detail.numFrame or nil,
    }
  end
  local exteriorModel = {}
  for _, record in ipairs(report.exteriorList) do
    exteriorModel[record.memberId] = record
  end
  for _, m in ipairs(report.models) do
    if m.archive == "exterior_build_models" then
      local record = exteriorModel[m.memberId]
      local assoc = {}
      if record then
        for _, resourceId in ipairs(record.ids) do
          local res = resourceById[resourceId]
          assoc[#assoc + 1] =
            string.format("%d(%s)", resourceId, res and (res.magic .. " " .. tostring(res.name)) or "missing")
        end
      end
      local sbc = {}
      for key in pairs(m.commands) do
        if key:sub(1, 8) ~= "NODEDESC" then
          sbc[#sbc + 1] = key
        end
      end
      table.sort(sbc)
      local gx = {}
      for key in pairs(m.gxMtx) do
        gx[#gx + 1] = key
      end
      table.sort(gx)
      add(
        "anim-model\t%d\t%s\tscaleRule=%s\ttexMtxMode=%d\tsbc=%s\tgxMtx=%s\tanims=%s",
        m.memberId,
        m.modelName,
        m.scalingRuleName,
        m.texMtxMode,
        #sbc > 0 and table.concat(sbc, ",") or "-",
        #gx > 0 and table.concat(gx, ",") or "-",
        #assoc > 0 and table.concat(assoc, ",") or "none"
      )
    end
  end

  add(
    "anim-inventory\tresources\t%s",
    table.concat(
      (function()
        local parts = {}
        for _, fmt in ipairs({ "NSBCA", "NSBTA", "NSBTP", "NSBMA", "NSBVA" }) do
          parts[#parts + 1] = fmt .. "=" .. tostring(formatCounts[fmt] or 0)
        end
        return parts
      end)(),
      ","
    )
  )
  add("anim-inventory\texterior-list\t%d\tinterior-list\t%d", #report.exteriorList, #report.interiorList)
  add("anim-inventory\tmodels\t%d", #report.models)
  for _, s in ipairs(report.skipped) do
    add("anim-inventory\tskipped\t%s:%d\t%s\t%s", s.archive, s.memberId, s.code, s.message)
  end
  return L
end

return AnimationInventory
