-- SSEQ/SBNK/SWAR decode and the offline effect renderer: event-stream
-- normalization, instrument layouts, sample decoding, and the finite-end
-- rendering contract for the scoped Start Menu effects. Fixtures are built
-- by hand from the GBATEK layouts; the real gs_sound_data.sdat gated the
-- same shapes.

local Assert = require("tests.support.Assert")
local SseqDecoder = require("romdump.src.digest.SseqDecoder")
local SbnkDecoder = require("romdump.src.digest.SbnkDecoder")
local SwarDecoder = require("romdump.src.digest.SwarDecoder")
local SseqRenderer = require("romdump.src.digest.SseqRenderer")

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

local function sseqFile(tracks)
  -- tracks: array of event byte strings. A single track starts directly at
  -- the data offset; a multitrack file starts with the 0xFE used-tracks
  -- bitmap (u16) followed by 0x93 track pointers naming the extra tracks.
  local first = tracks[1]
  local payload
  if #tracks == 1 and (not first or first:byte(1) ~= 0xFE) then
    payload = first
  else
    local bitmap = 0
    for t = 1, #tracks do
      bitmap = bitmap + 2 ^ (t - 1)
    end
    local pointers = {}
    local body = {}
    local offset = 3 + (#tracks - 1) * 5 + #tracks[1]
    for t = 2, #tracks do
      pointers[#pointers + 1] = string.char(0x93, t - 1)
        .. string.char(offset % 256, math.floor(offset / 256) % 256, math.floor(offset / 65536) % 256)
      body[#body + 1] = tracks[t]
      offset = offset + #tracks[t]
    end
    payload = string.char(0xFE) .. u16(bitmap) .. table.concat(pointers) .. tracks[1] .. table.concat(body)
  end
  local dataOffset = 0x1C
  return "SSEQ"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(dataOffset + #payload)
    .. u16(0x10)
    .. u16(1)
    .. "DATA"
    .. u32(8 + 4 + #payload)
    .. u32(dataOffset)
    .. payload
end

local function sbnkFile(instruments)
  -- instruments: array of { fRecord, data } ; data is embedded as one blob
  -- at absolute file offsets after the record table.
  local blob = {}
  local records = {}
  local offset = 0x18 + 0x20 + 4 + #instruments * 4
  for _, inst in ipairs(instruments) do
    records[#records + 1] = string.char(inst.fRecord) .. u16(offset) .. string.char(0)
    blob[#blob + 1] = inst.data
    offset = offset + #inst.data
  end
  local payload = string.rep("\0", 0x20) .. u32(#instruments) .. table.concat(records) .. table.concat(blob)
  return "SBNK"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x1C + #payload)
    .. u16(0x10)
    .. u16(1)
    .. "DATA"
    .. u32(8 + #payload)
    .. payload
end

local function swarFile(samples)
  -- samples: array of { waveType, rate, data } at absolute file offsets.
  local offsets = {}
  local body = {}
  local offset = 0x18 + 0x20 + 4 + #samples * 4
  for _, s in ipairs(samples) do
    offsets[#offsets + 1] = offset
    body[#body + 1] = s
    offset = offset + #s
  end
  local offsetTable = {}
  for _, off in ipairs(offsets) do
    offsetTable[#offsetTable + 1] = u32(off)
  end
  local payload = string.rep("\0", 0x20) .. u32(#samples) .. table.concat(offsetTable) .. table.concat(body)
  return "SWAR"
    .. string.char(0xFF, 0xFE)
    .. u16(0x0100)
    .. u32(0x1C + #payload)
    .. u16(0x10)
    .. u16(1)
    .. "DATA"
    .. u32(8 + #payload)
    .. payload
end

local function sampleBlock(waveType, rate, data)
  return string.char(waveType, 0) .. u16(rate) .. u16(0) .. u16(0) .. u32(math.ceil(#data / 4)) .. data
end

function T.sseq_normalizes_events_and_tempo()
  local data = sseqFile({
    string.char(0xE1, 0x78, 0x00, 0x81, 0x03, 0xC1, 0x7F, 0x48, 0x44, 0x05, 0x80, 0x06, 0x80, 0x0C, 0xFF),
  })
  local sseq = assert(SseqDecoder.decode(data))
  Assert.equal(#sseq.tracks, 1)
  local events = sseq.tracks[1].events
  Assert.deepEqual(events[1], { kind = "tempo", value = 0x78 })
  Assert.deepEqual(events[2], { kind = "program", program = 3, bank = 0 })
  Assert.deepEqual(events[3], { kind = "volume", value = 0x7F })
  Assert.deepEqual(events[4], { kind = "note", velocity = 0x48, gate = 0x44 })
  Assert.deepEqual(events[5], { kind = "note", velocity = 0x05, gate = 0x80 + 0x06 - 0x80 })
  Assert.deepEqual(events[6], { kind = "rest", ticks = 12 })
  Assert.deepEqual(events[7], { kind = "end" })
end

function T.sseq_multitrack_offsets_resolve()
  local track0 = string.char(0xC7, 0x00, 0xFF)
  local track1 = string.char(0xC1, 0x40, 0xFF)
  local data = sseqFile({ track0, track1 })
  local sseq = assert(SseqDecoder.decode(data))
  Assert.equal(#sseq.tracks, 2)
  Assert.deepEqual(sseq.tracks[1].events[1], { kind = "mono", value = 0 })
  Assert.deepEqual(sseq.tracks[2].events[1], { kind = "volume", value = 0x40 })
end

function T.sseq_rejects_unsupported_events()
  local data = sseqFile({ string.char(0xA0, 0xFF) })
  local out, err = SseqDecoder.decode(data)
  Assert.isNil(out)
  Assert.equal(assert(err).code, "SSEQ_EVENT_UNSUPPORTED")
end

function T.sbnk_decodes_direct_range_and_regional_instruments()
  local direct = u16(3) .. u16(1) .. string.char(60, 10, 20, 30, 40, 50)
  local function entry(swav, swar, note, atk, dec, sus, rel, pan)
    return u16(1) .. u16(swav) .. u16(swar) .. string.char(note, atk, dec, sus, rel, pan)
  end
  local rangeData = string.char(60, 62, 0, 1)
    .. entry(5, 1, 60, 1, 2, 3, 4, 5)
    .. entry(6, 1, 61, 6, 7, 8, 9, 10)
    .. entry(7, 1, 62, 6, 7, 8, 9, 10)
  -- Regional entries follow the shipped 12-byte shape: a 32-bit swar
  -- reference, the swav byte, the note, and the six ADSR bytes.
  local function regionalEntry(swar, swav, note, atk, dec, sus, rel)
    return u32(swar) .. string.char(swav, note, atk, dec, sus, rel) .. u16(1)
  end
  local regionalData = string.char(60, 0, 0, 0, 0, 0, 0, 0) .. u16(1) .. regionalEntry(0, 7, 61, 11, 12, 13, 14)
  local data = sbnkFile({
    { fRecord = 1, data = direct },
    { fRecord = 16, data = rangeData },
    { fRecord = 17, data = regionalData },
  })
  local bank = assert(SbnkDecoder.decode(data))
  Assert.deepEqual(bank.instruments[0], {
    kind = "direct",
    entry = { swav = 3, swar = 1, note = 60, attack = 10, decay = 20, sustain = 30, release = 40, pan = 50 },
  })
  Assert.equal(bank.instruments[1].kind, "range")
  Assert.equal(bank.instruments[1].lower, 60)
  Assert.equal(bank.instruments[1].entries[61].swav, 6)
  Assert.equal(bank.instruments[2].kind, "regional")
  Assert.equal(bank.instruments[2].regions[1].regionEnd, 60)
  Assert.equal(bank.instruments[2].regions[1].entry.swav, 7)
end

function T.swar_decodes_pcm8_and_pcm16_samples()
  local pcm8 = sampleBlock(0, 16000, string.char(0x80, 0x81, 0x7F))
  local pcm16 = sampleBlock(1, 22050, string.char(0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80))
  local data = swarFile({ pcm8, pcm16 })
  local swar = assert(SwarDecoder.decode(data))
  Assert.equal(swar.samples[0].waveType, 0)
  Assert.equal(swar.samples[0].sampleRate, 16000)
  Assert.equal(swar.samples[1].waveType, 1)
  Assert.equal(swar.samples[1].sampleRate, 22050)
end

-- A one-note sequence with a single PCM16 sample renders a finite mono
-- stream at the sample's rate, and the note's gate bounds its length.
function T.renderer_produces_a_finite_pcm16_stream()
  local sseq = assert(SseqDecoder.decode(sseqFile({
    string.char(0xE1, 0x78, 0x00, 0x81, 0x00, 0x48, 0x78, 0xFF),
  })))
  local direct = u16(0) .. u16(0) .. string.char(60, 127, 127, 127, 127, 64)
  local bank = assert(SbnkDecoder.decode(sbnkFile({ { fRecord = 1, data = direct } })))
  local pcm = string.char(0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80)
  local swar = assert(SwarDecoder.decode(swarFile({ sampleBlock(1, 8000, pcm) })))
  local result = assert(SseqRenderer.render(sseq, bank, { swar }))
  Assert.equal(result.sampleRate, 8000)
  Assert.isTrue(result.frameCount > 0 and result.frameCount < 20000, "a 120-tick note at 120 BPM is about a second")
  Assert.equal(#result.pcm16 % 2, 0)
  -- The mix is not silent: the note's sample is non-zero.
  local peak = 0
  for i = 1, #result.pcm16, 2 do
    local v = string.byte(result.pcm16, i) + string.byte(result.pcm16, i + 1) * 256
    if v >= 32768 then
      v = v - 65536
    end
    if math.abs(v) > peak then
      peak = math.abs(v)
    end
  end
  Assert.isTrue(peak > 100, "the rendered note must be audible")
end

function T.renderer_fails_on_missing_samples()
  local sseq = assert(SseqDecoder.decode(sseqFile({ string.char(0x81, 0x00, 0x48, 0x10, 0xFF) })))
  local direct = u16(9) .. u16(0) .. string.char(60, 127, 127, 127, 127, 64)
  local bank = assert(SbnkDecoder.decode(sbnkFile({ { fRecord = 1, data = direct } })))
  local swar = assert(SwarDecoder.decode(swarFile({ sampleBlock(1, 8000, string.char(0, 0)) })))
  local out, err = SseqRenderer.render(sseq, bank, { swar })
  Assert.isNil(out)
  Assert.equal(assert(err).code, "SND_SAMPLE_MISSING")
end

return { tests = T }
