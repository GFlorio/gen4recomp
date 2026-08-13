-- Real-ROM validation of the animation decoders: every member of the HGSS
-- field animation archive (a/1/0/6) must decode through NitroAnimation,
-- and the archive facts must hold -- all NSBCA curve limits equal numFrame,
-- all JNT target offsets resolve, and the door rotation sweep matches its
-- pivot entries.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local Nsbca = require("romdump.src.digest.nitro.Nsbca")
local Nsbta = require("romdump.src.digest.nitro.Nsbta")
local Nsbtp = require("romdump.src.digest.nitro.Nsbtp")
local Nsbma = require("romdump.src.digest.nitro.Nsbma")

local T = {}

-- Every animation resource decodes; every sampled curve limit equals the
-- animation's numFrame (verified pattern across all 85 NSBCA members).
function T.all_animation_members_decode(romFs)
  local narc = assert(romFs:openNarc("build_anim"))
  local count = narc:memberCount()
  Assert.equal(count, 273, "field animation archive member count")
  local formats = { NSBCA = 0, NSBTA = 0, NSBTP = 0, NSBMA = 0 }
  for memberId = 0, count - 1 do
    local bytes = assert(narc:readMember(memberId))
    local decoded, err = NitroAnimation.decode(bytes, { alias = "build_anim", memberId = memberId })
    assert(decoded, "member " .. memberId .. ": " .. tostring(err and err.message))
    formats[decoded.format] = formats[decoded.format] + 1
    Assert.equal(#decoded.animations, 1, "one animation per member")
    local r = BinaryReader.new(decoded.bytes, "sec")
    for _, anim in ipairs(decoded.animations) do
      local res = anim.resource
      Assert.equal(res.numFrame >= 2, true, "sane frame count")
      if decoded.format == "NSBCA" then
        -- Curve limits match numFrame; sampling any frame stays in bounds.
        for _, t in ipairs(res.targets) do
          for _, axis in ipairs({ "x", "y", "z" }) do
            local c = t.channels.trans[axis]
            if c.source == "curve" then
              Assert.equal(c.curve.limit, res.numFrame, "trans limit")
            end
            c = t.channels.scale[axis]
            if c.source == "curve" then
              Assert.equal(c.curve.limit, res.numFrame, "scale limit")
            end
          end
          local rot = t.channels.rot
          if rot.source == "curve" then
            Assert.equal(rot.curve.limit, res.numFrame, "rot limit")
          end
        end
        -- Sample the middle frame of every target (all field members use the
        -- integer sampler; this exercises every channel type in the corpus).
        local mid = math.floor(res.numFrame / 2) * 4096
        for i = 0, #res.targets - 1 do
          local s = Nsbca.sample(r, res, i, mid)
          if s.rot then
            for _, v in ipairs(s.rot) do
              Assert.isTrue(math.abs(v) < 0x80000000, "rotation cell bounded")
            end
          end
        end
      elseif decoded.format == "NSBTA" then
        -- NSBTA curve limits equal numFrame like NSBCA (census: 217/217
        -- curve channels across the 99 members), so the compile path may
        -- assert the same invariant.
        for _, t in ipairs(res.targets) do
          for _, name in ipairs({ "transS", "transT", "rot", "scaleS", "scaleT" }) do
            local c = t.channels[name]
            if c.source == "curve" then
              Assert.equal(c.limit, res.numFrame, name .. " limit")
            end
          end
        end
        -- Sample the middle frame of every target: exercises the constant
        -- channels (including non-identity packed rotations), the sampled
        -- fx16/fx32 vector channels, and the packed rotation pairs.
        local mid = math.floor(res.numFrame / 2) * 4096
        for i = 0, #res.targets - 1 do
          local s = Nsbta.sample(r, res, i, mid)
          for _, name in ipairs({ "transS", "transT", "scaleS", "scaleT" }) do
            local v = s[name]
            if v ~= nil and v >= 0x80000000 then
              v = v - 4294967296
            end
            Assert.isTrue(v == nil or math.abs(v) < 0x10000000, "texture SRT cell bounded")
          end
          if s.rot then
            Assert.isTrue(math.abs(s.rot.sin) < 0x10000, "rotation pair bounded")
            Assert.isTrue(math.abs(s.rot.cos) < 0x10000, "rotation pair bounded")
          end
        end
      elseif decoded.format == "NSBTP" then
        for _, t in ipairs(res.targets) do
          Assert.equal(t.keyCount, #t.keys, "key count matches array")
          for _, k in ipairs(t.keys) do
            Assert.isTrue(k.texIdx < res.numTextures, "texture index in range")
            Assert.isTrue(k.plttIdx == 0xFF or k.plttIdx < res.numPalettes, "palette index in range")
          end
          -- The last key's frame is within the animation.
          Assert.isTrue(t.keys[#t.keys].frame < res.numFrame, "last key frame < numFrame")
        end
      end
    end
  end
  Assert.equal(formats.NSBCA, 85, "NSBCA count")
  Assert.equal(formats.NSBTA, 99, "NSBTA count")
  Assert.equal(formats.NSBTP, 79, "NSBTP count")
  Assert.equal(formats.NSBMA, 10, "NSBMA count")
  -- No NSBVA pin: a VIS0 member would fail the decode above
  -- (ANM_UNKNOWN_FILE_MAGIC) and fail this test on its own.
end

-- The real door_op member: node 0, rotation animated through 8 pivot keys,
-- translation and scale from the model.
function T.door_op_rotation_sweeps(romFs)
  local narc = assert(romFs:openNarc("build_anim"))
  local bytes = assert(narc:readMember(1)) -- door_op
  local decoded = assert(NitroAnimation.decode(bytes))
  local res = decoded.animations[1].resource
  Assert.equal(res.numFrame, 8, "door_op frame count")
  Assert.equal(#res.targets, 1)
  local target = res.targets[1]
  Assert.equal(target.nodeIndex, 0)
  Assert.isTrue(target.channels.trans.x.source == "model", "door translation from model")
  Assert.isTrue(target.channels.rot.source == "curve", "door rotation animated")

  local r = BinaryReader.new(decoded.bytes, "sec")
  local s0 = Nsbca.sample(r, res, 0, 0)
  local s7 = Nsbca.sample(r, res, 0, 7 * 4096)
  -- Frame 0: pivot entry 0 (A=1, B=0) -- the closed pose.
  Assert.isTrue(math.abs(s0.rot[1] - 0x1000) < 0x40, "closed pose A = 1")
  -- Frame 7: the last pivot entry is {0x22, A=0, B=0x1000} (pivot 2, signC).
  Assert.isTrue(math.abs(s7.rot[1]) < 0x40, "open pose A = 0")
  Assert.isTrue(math.abs(s7.rot[5] - 0x1000) < 0x40, "open pose B = 1")
  Assert.isTrue(math.abs(s7.rot[7] + 0x1000) < 0x40, "open pose C = -B")
  Assert.isTrue(math.abs(s7.rot[3] - 0x1000) < 0x40, "pivot cell")
end

-- The real gym doors are NSBTA (texture-SRT): member 121/122 pair, and the
-- census's most-referenced BTP pair (pc_mb) must select variants by frame.
function T.material_animation_members(romFs)
  local narc = assert(romFs:openNarc("build_anim"))

  -- Member 7 = pc_mb (BTP): keys every 4 frames, 4 textures.
  local btp = assert(NitroAnimation.decode(assert(narc:readMember(7))))
  local res = btp.animations[1].resource
  Assert.equal(res.numFrame, 68)
  Assert.equal(#res.textureNames, 4)
  local k = Nsbtp.keyAt(res, 0, 67)
  Assert.equal(k.frame, 64)
  Assert.equal(k.texIdx, 0)

  -- A BMA member (member 119 = psentry_rode): constant colors + alpha curve.
  local bma = assert(NitroAnimation.decode(assert(narc:readMember(119))))
  local bmaRes = bma.animations[1].resource
  Assert.equal(bmaRes.numFrame, 60)
  local br = BinaryReader.new(bma.bytes, "sec")
  local s = Nsbma.sample(br, bmaRes, 0, 0)
  Assert.equal(s.alpha, 31, "alpha starts opaque")
  -- The alpha key array fades to 0 well before the 60-frame limit.
  local sMid = Nsbma.sample(br, bmaRes, 0, 30 * 4096)
  Assert.isTrue(sMid.alpha <= 1, "alpha faded by frame 30 (saw " .. tostring(sMid.alpha) .. ")")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
