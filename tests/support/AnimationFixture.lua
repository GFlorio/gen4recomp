-- Synthetic Nitro 3D animation resources for unit tests: BCA0/JNT0, BTA0/SRT0,
-- BTP0/PAT0, BMA0/MAT0 files whose byte layouts match the verified
-- real-format layouts (see the NitroAnimation modules). Test-only.

local BinaryWriter = require("libs.rom.src.BinaryWriter")
local NitroBuilder = require("tests.support.NitroBuilder")

local AnimationFixture = {}

local u8, u16, u32 = NitroBuilder.u8, NitroBuilder.u16, NitroBuilder.u32

local function s16(v)
  if v < 0 then
    v = v + 65536
  end
  return math.floor(v) % 65536
end

local function fx16(v)
  return s16(v * 4096)
end
-- DS fixed point is 1.M.12 (4096 per unit), the same scale as the model
-- node SRT records -- the geometry engine consumes these values directly as
-- MTX_TRANS/MTX_SCALE params (NNSi_G3dSendJointSRTBasic), so NSBCA
-- constants and fx32-storage keys are authored at 12-bit fraction, exactly
-- like the verified real ROM members.
local function fx32(v)
  return math.floor(v * 4096) % 4294967296
end

-- Wrap a section body (dict + record) in a Nitro file with the given magic.
local function file(magic, section, body)
  return NitroBuilder.file(magic, { { magic = section, body = body } })
end

local function name16(name)
  return name .. string.rep("\0", 16 - #name)
end

-- Packed rotation word: sin in the low half, cos in the high half.
local function packedSinCos(sin, cos)
  return s16(sin * 4096) % 65536 + (s16(cos * 4096) % 65536) * 65536
end

-- Build the name dictionary followed by `record`, with each entry's u32
-- payload set to the record's section-relative offset. The dict begins at
-- section offset 8, so the payload is 8 + the dict length; the probe dict
-- has the same length as the real one (the payload is a u32 either way).
local function dictWithRecord(entries, record)
  local probe = NitroBuilder.dict(entries)
  local sized = {}
  for i, e in ipairs(entries) do
    sized[i] = { name = e.name, data = u32(8 + #probe) }
  end
  return NitroBuilder.dict(sized) .. record
end

-- ---- NSBCA / JNT0 ----

-- Channel byte string for one target, in the fixed channel order. Each entry
-- is "model" | { const = u32 } | { curve = { flag = u32, key = name } }.
local function jntChannels(channels, keyOffsets)
  local out = {}
  local function push(bytes)
    out[#out + 1] = bytes
  end
  local function axis(chan)
    if chan == nil or chan == "model" then
      return
    end
    if chan.const then
      push(u32(chan.const))
      return
    end
    push(u32(chan.curve.flag))
    push(u32(keyOffsets[chan.curve.key]))
  end
  for _, axisName in ipairs({ "x", "y", "z" }) do
    axis(channels.trans and channels.trans[axisName])
  end
  local rot = channels.rot
  if rot ~= nil and rot ~= "model" then
    if rot.const then
      push(u32(rot.const))
    else
      push(u32(rot.curve.flag))
      push(u32(keyOffsets[rot.curve.key]))
    end
  end
  for _, axisName in ipairs({ "x", "y", "z" }) do
    local chan = channels.scale and channels.scale[axisName]
    if chan ~= nil and chan ~= "model" then
      if chan.const then
        push(u32(chan.const))
        push(u32(chan.constInv or 0x1000))
      else
        push(u32(chan.curve.flag))
        push(u32(keyOffsets[chan.curve.key]))
      end
    end
  end
  return table.concat(out)
end

-- Assemble one JNT0 record. opts: numFrame, numAnm, anmFlags, targets,
-- rotData, pivotData, keyData (name -> bytes).
local function buildJntRecord(opts)
  local numAnm = opts.numAnm or #opts.targets
  local headerLen = 0x14
  local tableLen = 2 * numAnm

  local function channelSize(chan, constSize)
    if chan == nil or chan == "model" then
      return 0
    end
    if chan.const then
      return constSize
    end
    return 8
  end
  local function targetSize(t)
    local size = 4
    for _, axisName in ipairs({ "x", "y", "z" }) do
      local c = t.channels and t.channels.trans and t.channels.trans[axisName]
      size = size + channelSize(c, 4)
    end
    size = size + channelSize(t.channels and t.channels.rot, 4)
    for _, axisName in ipairs({ "x", "y", "z" }) do
      local c = t.channels and t.channels.scale and t.channels.scale[axisName]
      size = size + channelSize(c, 8)
    end
    return size
  end

  local ofsTarget = {}
  local cursor = headerLen + tableLen
  for i, t in ipairs(opts.targets) do
    ofsTarget[i] = cursor
    cursor = cursor + targetSize(t)
  end
  local ofsRotData = cursor
  cursor = cursor + #(opts.rotData or "")
  local ofsPivotData = cursor
  cursor = cursor + #(opts.pivotData or "")

  local keyOffsets = {}
  for name, bytes in pairs(opts.keyData or {}) do
    keyOffsets[name] = cursor
    cursor = cursor + #bytes
  end

  local bw = BinaryWriter.new()
  bw:bytes("J\0AC")
  bw:u16(opts.numFrame or 1)
  bw:u16(numAnm)
  bw:u32(opts.anmFlags or 0)
  bw:u32(ofsRotData)
  bw:u32(ofsPivotData)
  for _, ofs in ipairs(ofsTarget) do
    bw:u16(ofs)
  end
  for _, t in ipairs(opts.targets) do
    -- The target's node index lives in flag bits 24-31 (NNSG3dResAnmJnt
    -- flag >> 24); the fixture table's nodeIndex field is that byte.
    bw:u32(t.flag + (t.nodeIndex or 0) * 0x1000000)
    bw:bytes(jntChannels(t.channels, keyOffsets))
  end
  bw:bytes(opts.rotData or "")
  bw:bytes(opts.pivotData or "")
  for _, bytes in pairs(opts.keyData or {}) do
    bw:bytes(bytes)
  end
  return bw:tostring()
end

local function pivotTable(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = u16(e.control or 0x0024) .. u16(fx16(e.a)) .. u16(fx16(e.b))
  end
  return table.concat(out)
end

-- One door-like target with an 8-key pivot rotation (like the real
-- `door_op`): translation and scale from the model. `trailingBytes` appends
-- unrelated data after the rotation key array inside the JNT0 section, to
-- exercise the final-curve bound (the key area is the record tail, so the
-- final curve extends to the section end).
function AnimationFixture.jntDoor(anmFlags, trailingBytes)
  local entries = {}
  for i = 0, 7 do
    entries[#entries + 1] = { control = 0x0024, a = 1 - i / 16, b = i / 16 }
  end
  local keys = {}
  for i = 0, 7 do
    keys[#keys + 1] = u16(0x8000 + i)
  end
  local record = buildJntRecord({
    numFrame = 8,
    anmFlags = anmFlags or 0,
    targets = {
      {
        nodeIndex = 0,
        flag = 0x00003A3A,
        channels = {
          trans = { x = "model", y = "model", z = "model" },
          rot = { curve = { flag = 0x00080000, key = "rot" } },
          scale = { x = "model", y = "model", z = "model" },
        },
      },
    },
    rotData = pivotTable(entries),
    keyData = { rot = table.concat(keys) .. (trailingBytes or "") },
  })
  return file("BCA0", "JNT0", dictWithRecord({ { name = "door_op", data = u32(0) } }, record))
end

-- All channels animated: fx16 trans curves, pivot rot curve, fx32 scale
-- pairs. `rateFlag` varies the sampling rate (half/quarter rate add
-- 0x40000000 / 0x80000000); keys then cover 2/4 frames per key. `limit`
-- overrides the authored curve limit (the real-format invariant is
-- limit == numFrame; a caller passing a smaller value authors the malformed
-- shape the compiler must reject).
function AnimationFixture.jntFull(rateFlag, keyCount, numFrame, limit)
  keyCount = keyCount or 8
  numFrame = numFrame or 8
  local flag = (rateFlag or 0) + (limit or numFrame) * 0x10000
  local flagFx16 = flag + 0x20000000
  -- (values stay within the fx16 range; the caller's expectations match)
  local function transKeys(base)
    local out = {}
    for i = 0, keyCount - 1 do
      out[#out + 1] = u16(fx16(base + i * 2))
    end
    return table.concat(out)
  end
  local function scaleKeys()
    local out = {}
    for i = 0, keyCount - 1 do
      out[#out + 1] = u32(fx32(1 + i / 4))
      out[#out + 1] = u32(fx32(1 / (1 + i / 4)))
    end
    return table.concat(out)
  end
  local rotKeys = {}
  for i = 0, keyCount - 1 do
    rotKeys[#rotKeys + 1] = u16(0x8000 + i % 2)
  end
  local record = buildJntRecord({
    numFrame = numFrame,
    targets = {
      {
        nodeIndex = 3,
        flag = 0,
        channels = {
          trans = {
            x = { curve = { flag = flagFx16, key = "tx" } },
            y = { curve = { flag = flagFx16, key = "ty" } },
            z = { curve = { flag = flagFx16, key = "tz" } },
          },
          rot = { curve = { flag = flagFx16, key = "rot" } },
          scale = {
            x = { curve = { flag = flag, key = "sx" } },
            y = { curve = { flag = flag, key = "sy" } },
            z = { curve = { flag = flag, key = "sz" } },
          },
        },
      },
    },
    rotData = pivotTable({ { a = 1, b = 0 }, { a = 0, b = 1 } }),
    keyData = {
      tx = transKeys(0),
      ty = transKeys(1),
      tz = transKeys(0) .. u16(fx16(1)),
      rot = table.concat(rotKeys),
      sx = scaleKeys(),
      sy = scaleKeys(),
      sz = scaleKeys(),
    },
  })
  return file("BCA0", "JNT0", dictWithRecord({ { name = "full", data = u32(0) } }, record))
end

-- Constant-track targets: trans and rot constants, scale constants with
-- inverse pairs, and a whole-model target.
function AnimationFixture.jntConstants()
  local record = buildJntRecord({
    numFrame = 2,
    targets = {
      {
        nodeIndex = 1,
        flag = 0x000006F8, -- trans consts, rot+scale from model
        channels = {
          trans = { x = { const = fx32(10) }, y = { const = fx32(20) }, z = { const = fx32(30) } },
          rot = "model",
          scale = { x = "model", y = "model", z = "model" },
        },
      },
      {
        nodeIndex = 2,
        flag = 0x00000706, -- rot const, trans+scale from model
        channels = {
          trans = { x = "model", y = "model", z = "model" },
          rot = { const = 0x8001 },
          scale = { x = "model", y = "model", z = "model" },
        },
      },
      {
        nodeIndex = 4,
        flag = 0x000038C6, -- scale consts, trans+rot from model
        channels = {
          trans = { x = "model", y = "model", z = "model" },
          rot = "model",
          scale = {
            x = { const = fx32(2), constInv = fx32(0.5) },
            y = { const = fx32(3), constInv = fx32(1 / 3) },
            z = { const = fx32(4), constInv = fx32(0.25) },
          },
        },
      },
      { nodeIndex = 5, flag = 0x00000001, channels = {} },
      -- Rot constant with bit 7 set but bit 6 clear: the decoder's rot-mode
      -- gate tests bit 6 only (the asm's fromModel bit, `ands r5, #0x40`),
      -- NOT the full 0xC0 mode field, so this decodes as a constant, not
      -- from the model. The encoder sets both bits for model-sourced
      -- rotation, so no real member exercises this corner.
      {
        nodeIndex = 6,
        flag = 0x00000786, -- trans mode + rot const (bit 7, no bit 6) + scale mode
        channels = {
          trans = { x = "model", y = "model", z = "model" },
          rot = { const = 0x8000 },
          scale = { x = "model", y = "model", z = "model" },
        },
      },
    },
    rotData = pivotTable({ { a = 1, b = 0 }, { a = 0, b = 1 } }),
  })
  return file("BCA0", "JNT0", dictWithRecord({ { name = "consts", data = u32(0) } }, record))
end

-- A JNT whose rotation keys use the compressed form (bit 15 clear).
function AnimationFixture.jntCompressed()
  local keys = {}
  for i = 0, 3 do
    keys[#keys + 1] = u16(i)
  end -- compressed indices 0..3
  local compEntries = {}
  for i = 0, 3 do
    -- Entry with nonzero low-3-bit remainders to exercise the packing.
    local e = { 0x2000 + i, 0x2000, 0, 0x1003, 0x1005 }
    local out = {}
    for _, v in ipairs(e) do
      out[#out + 1] = u16(v)
    end
    compEntries[#compEntries + 1] = table.concat(out)
  end
  local record = buildJntRecord({
    numFrame = 4,
    targets = {
      {
        nodeIndex = 0,
        flag = 0x00003A3A,
        channels = {
          trans = { x = "model", y = "model", z = "model" },
          rot = { curve = { flag = 0x00040000, key = "rot" } },
          scale = { x = "model", y = "model", z = "model" },
        },
      },
    },
    pivotData = table.concat(compEntries),
    keyData = { rot = table.concat(keys) },
  })
  return file("BCA0", "JNT0", dictWithRecord({ { name = "comp", data = u32(0) } }, record))
end

-- ---- NSBTA / SRT0 ----

-- Assemble one SRT0 record with 1 target. opts: numFrame, channels =
-- { scaleS, scaleT, rot, transS, transT }, each { const = u32 } or
-- { fx16 = bool, keys = { u32-or-u16 values } } (rot keys are packed u32
-- sin/cos pairs when `packed`). The channel order follows GetTexSRTAnm_
-- (scale pair first, then rot, then the translation pair).
local function buildSrtRecord(opts)
  local numFrame = opts.numFrame or 60
  local headerLen = 0x1C
  local stride = 0x28
  local ofsTargets = 0x14
  local recordLen = headerLen + 4 + stride + 16 -- header, stride pair, record, name

  -- Key arrays after the name; compute record-relative offsets.
  local keyAt = recordLen
  local cursor = keyAt
  local offsets = {}
  local order = { "scaleS", "scaleT", "rot", "transS", "transT" }
  for _, name in ipairs(order) do
    local c = opts.channels[name]
    if c.const == nil then
      offsets[name] = cursor
      cursor = cursor + #c.keys * (c.packed and 4 or (c.fx16 and 2 or 4))
    end
  end

  local bw = BinaryWriter.new()
  bw:bytes("M\0AT")
  bw:u16(numFrame)
  bw:u16(0)
  bw:u16(0x0100)
  bw:u16(0x88)
  bw:u16(8)
  bw:u16(ofsTargets)
  bw:u32(0x17F)
  bw:u16(0x3D)
  bw:u16(1)
  bw:u16(0x013A)
  bw:u16(0x0102)
  bw:u16(stride)
  bw:u16(0x2C) -- name table offset (name follows the records at +0x48)
  for _, name in ipairs(order) do
    local c = opts.channels[name]
    if c.const then
      bw:u32(0x30000000 + numFrame)
      bw:u32(c.const)
    else
      -- `limit` overrides the authored curve limit (the real-format
      -- invariant is limit == numFrame; a smaller value authors the
      -- malformed shape the compiler must reject).
      local flag = c.limit or numFrame
      if c.fx16 then
        flag = flag + 0x10000000
      end
      bw:u32(flag)
      bw:u32(offsets[name])
    end
  end
  bw:bytes(name16("en_sp1_3"))
  for _, name in ipairs(order) do
    local c = opts.channels[name]
    if c.const == nil then
      for _, v in ipairs(c.keys) do
        if c.fx16 and not c.packed then
          bw:bytes(u16(v))
        else
          bw:bytes(u32(v))
        end
      end
    end
  end
  return bw:tostring()
end

-- Water-like SRT (the real en_sp1 shape): identity scales and rotation,
-- zero translation S, and a sampled fx16 translation-T curve (the scroll).
function AnimationFixture.srtWater()
  local record = buildSrtRecord({
    numFrame = 8,
    channels = {
      scaleS = { const = 0x1000 },
      scaleT = { const = 0x1000 },
      rot = { const = 0x10000000 },
      transS = { const = 0 },
      transT = { fx16 = true, keys = { fx16(1), fx16(2), fx16(3), fx16(4), fx16(5), fx16(6), fx16(7), fx16(8) } },
    },
  })
  return file("BTA0", "SRT0", dictWithRecord({ { name = "en_sp1", data = u32(0) } }, record))
end

-- SRT with an animated rotation (packed sin/cos keys) and a translation-S
-- curve. `rotLimit` overrides the rotation channel's authored curve limit
-- (the real-format invariant is limit == numFrame; a smaller value authors
-- the malformed shape the compiler must reject).
function AnimationFixture.srtSpin(rotLimit)
  local record = buildSrtRecord({
    numFrame = 4,
    channels = {
      scaleS = { const = 0x1000 },
      scaleT = { const = 0x1000 },
      rot = {
        packed = true,
        limit = rotLimit,
        keys = {
          packedSinCos(0.5, 0.8660),
          packedSinCos(0.7071, 0.7071),
          packedSinCos(1, 0),
          packedSinCos(0.7071, -0.7071),
        },
      },
      transS = { keys = { 0, 0x1000, 0x2000, 0x3000 } },
      transT = { const = 0 },
    },
  })
  return file("BTA0", "SRT0", dictWithRecord({ { name = "spin", data = u32(0) } }, record))
end

-- SRT with a constant non-identity rotation (packed sin/cos word).
function AnimationFixture.srtConstRot()
  local record = buildSrtRecord({
    numFrame = 4,
    channels = {
      scaleS = { const = 0x1000 },
      scaleT = { const = 0x1000 },
      rot = { const = packedSinCos(0.5, 0.8660) },
      transS = { const = 0 },
      transT = { const = 0 },
    },
  })
  return file("BTA0", "SRT0", dictWithRecord({ { name = "constrot", data = u32(0) } }, record))
end

-- ---- NSBTP / PAT0 ----

-- pc_mb-like BTP: one target, 4 textures/palettes, keys every 4 frames.
function AnimationFixture.patPcMb()
  local numFrame = 68
  local keys = {}
  for i = 0, 16 do
    keys[#keys + 1] = u16(i * 4) .. u8(i % 4) .. u8(i % 4)
  end
  local texNames = {}
  for i = 1, 4 do
    texNames[#texNames + 1] = name16("pc_mb." .. i)
  end
  local plttNames = {}
  for i = 1, 4 do
    plttNames[#plttNames + 1] = name16("pc_mb." .. i .. "_pl")
  end

  local headerLen = 0x1C
  local targetBlock = 12 -- pre-record (stride, nameOfs) + key record
  local keyCount = 17
  local ofsKeys = headerLen + targetBlock + 16 -- after the name
  local ofsTexNames = ofsKeys + keyCount * 4
  local ofsPlttNames = ofsTexNames + #table.concat(texNames)

  local bw = BinaryWriter.new()
  bw:bytes("M\0PT")
  bw:u16(numFrame)
  bw:u8(4)
  bw:u8(4)
  bw:u16(ofsTexNames)
  bw:u16(ofsPlttNames)
  bw:u16(0x0100)
  bw:u16(0x2C)
  bw:u16(8)
  bw:u16(0x10)
  bw:u32(0x17F)
  bw:u16(0x26)
  bw:u16(1)
  bw:u16(8) -- stride
  bw:u16(0x0C) -- name table offset
  bw:u32(keyCount)
  bw:u16(0x0400) -- rate: one key every 4 frames
  bw:u16(ofsKeys)
  bw:bytes(name16("pc_mb"))
  for _, k in ipairs(keys) do
    bw:bytes(k)
  end
  bw:bytes(table.concat(texNames))
  bw:bytes(table.concat(plttNames))
  return file("BTP0", "PAT0", dictWithRecord({ { name = "pc_mb", data = u32(0) } }, bw:tostring()))
end

-- ---- NSBMA / MAT0 ----

-- psentry-like BMA: four constant colors plus a sampled alpha fade.
function AnimationFixture.matFade()
  local numFrame = 60
  local alphaKeys = {}
  for i = 0, 59 do
    alphaKeys[#alphaKeys + 1] = u8(math.max(0, 31 - i / 2))
  end

  local stride = 20
  local ofsTargets = 0x10
  local ofsAlpha = 0x1C + stride + 16 -- after header, flags, and name

  local bw = BinaryWriter.new()
  bw:bytes("M\0AM")
  bw:u16(numFrame)
  bw:u16(0)
  bw:u16(0x0100)
  bw:u16(0x38)
  bw:u16(8)
  bw:u16(ofsTargets)
  bw:u32(0x17F)
  bw:u16(0x45)
  bw:u16(1)
  bw:u16(stride) -- stride table at record + 8 + ofsTargets
  bw:u16(0x18) -- name table offset
  bw:u32(0x203C * 0x10000) -- constant diffuse (bit 13 of the value = const bit)
  bw:u32(0x203C * 0x10000) -- constant ambient
  bw:u32(0x203C * 0x10000) -- constant specular
  bw:u32(0x203C * 0x10000) -- constant emission
  bw:u32(numFrame * 0x10000 + ofsAlpha) -- alpha curve
  bw:bytes(name16("yuka2_lm3"))
  for _, b in ipairs(alphaKeys) do
    bw:bytes(b)
  end
  return file("BMA0", "MAT0", dictWithRecord({ { name = "psentry_rode", data = u32(0) } }, bw:tostring()))
end

return AnimationFixture
