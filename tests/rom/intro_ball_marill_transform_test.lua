-- Validates that the retained source displacement for the ball and marill
-- animation resource is observable through the decoder rather than collapsed
-- to a bare cell reference.

local Assert = require("tests.support.Assert")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function getBytes(archive, memberId)
  local Lz10 = require("romdump.src.digest.Lz10")
  local bytes = assert(archive:readMember(memberId))
  if string.byte(bytes, 1) == 0x10 then
    bytes = assert(Lz10.decode(bytes))
  end
  return bytes
end

local function resolveAnimationBytes(romFs, spec)
  local BinaryReader = require("libs.codec.src.BinaryReader")
  local res = assert(spec.resourceResolution, "spec needs resourceResolution")
  local resArchive = assert(romFs:openNarc(res.archive))
  local hdr = getBytes(resArchive, res.header)
  local reader = BinaryReader.new(hdr, "hdr")
  local off = spec.resourceSet * 32
  local animId = reader:u32le(off + 12)
  local tableBytes = getBytes(resArchive, res.animationTable)
  local tr = BinaryReader.new(tableBytes, "animTable")
  local records = {}
  local o = 4
  while true do
    local narcId = tr:u32le(o)
    if narcId == 0xFFFFFFFE then
      break
    end
    local fileId = tr:u32le(o + 4)
    local objectId = tr:u32le(o + 12)
    records[objectId] = { narcId = narcId, fileId = fileId }
    o = o + 24
  end
  local rec = assert(records[animId], "animation mapping missing for resourceSet " .. tostring(spec.resourceSet))
  assert(rec.narcId == res.sourceNarcId, "unexpected source archive for animation")
  local introArchive = assert(romFs:openNarc(spec.archive))
  local animBytes = getBytes(introArchive, rec.fileId)
  return animBytes, spec.animationIndex
end

function T.ball_marill_displacement_survives_decoding(romFs, versionId)
  local G2dDecoder = require("romdump.src.digest.G2dDecoder")
  local IntroAssets = require("romdump.src.config.IntroAssets")

  local specs = {
    IntroAssets.ball_open,
    IntroAssets.marill_appear,
    IntroAssets.marill,
  }

  local anyTransformed = false
  for _, spec in ipairs(specs) do
    local animBytes, selectedIndex = resolveAnimationBytes(romFs, spec)
    local first = assert(G2dDecoder.decodeAnimation(animBytes))
    local second = assert(G2dDecoder.decodeAnimation(animBytes))

    local anim = assert(first.anims[selectedIndex + 1], "selected animation missing")
    local anim2 = assert(second.anims[selectedIndex + 1], "second decode missing selected animation")
    Assert.equal(#anim.frames, #anim2.frames, "repeated decode must be stable frame count")

    for idx, frame in ipairs(anim.frames) do
      Assert.isTrue(type(frame.cell) == "number" and frame.cell >= 0, "cell remains valid at frame " .. idx)
      Assert.isTrue(type(frame.duration) == "number" and frame.duration > 0, "duration remains valid at frame " .. idx)

      local other = anim2.frames[idx]
      Assert.equal(frame.cell, other.cell, "cell stable across decodes at frame " .. idx)
      Assert.equal(frame.duration, other.duration, "duration stable across decodes at frame " .. idx)

      -- The decoder must expose displacement semantics beyond a bare cell
      -- reference. Before the pipeline correction every frame collapses to
      -- exactly cell+duration.
      local extraKeys = {}
      for k in pairs(frame) do
        if k ~= "cell" and k ~= "duration" then
          extraKeys[#extraKeys + 1] = k
        end
      end
      if #extraKeys == 0 then
        error(
          "animation element displacement was discarded: frame "
            .. idx
            .. " of the selected intro animation exposes only cell and duration",
          0
        )
      end

      -- Stability of the normalized displacement value.
      for _, k in ipairs(extraKeys) do
        local a, b = frame[k], other[k]
        if type(a) == "table" and type(b) == "table" then
          -- shallow table stability check for translation/scale tables
          for tk, tv in pairs(a) do
            if b[tk] ~= tv then
              error(
                "displacement value unstable across repeated decode at frame " .. idx .. " key " .. k .. "." .. tk,
                0
              )
            end
          end
        else
          if a ~= b then
            error("displacement value unstable across repeated decode at frame " .. idx .. " key " .. k, 0)
          end
        end
      end

      -- Detect a non-default translation/scale/rotation payload.
      for _, k in ipairs(extraKeys) do
        local v = frame[k]
        if type(v) == "table" then
          for _, inner in pairs(v) do
            if type(inner) == "number" and inner ~= 0 and inner ~= 1 then
              anyTransformed = true
            end
            if type(inner) == "table" then
              for _, n in pairs(inner) do
                if type(n) == "number" and n ~= 0 and n ~= 1 then
                  anyTransformed = true
                end
              end
            end
          end
        elseif type(v) == "number" and v ~= 0 and v ~= 1 then
          -- non-default numeric displacement
          anyTransformed = true
        elseif type(v) == "string" and v ~= "none" and v ~= "" then
          -- element kind string indicating non-trivial form
          anyTransformed = true
        end
      end
    end
  end

  if not anyTransformed then
    error("no selected ball/marill frame carries a non-default normalized placement transform", 0)
  end
end

return RomSuite.fromFacts(T)
