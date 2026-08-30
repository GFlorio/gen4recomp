-- Selects a normalized Nintendo instrument voice for a MIDI key.

local InstrumentSelector = {}

---@param instrument table
---@param midiKey integer
---@return table?
function InstrumentSelector.selectVoice(instrument, midiKey)
  if instrument.kind == "direct" then
    if instrument.voice.kind == "dummy" then
      return nil
    end
    return instrument.voice
  end
  if instrument.kind == "key_split" then
    for _, range in ipairs(instrument.ranges) do
      if midiKey >= range.lowKey and midiKey <= range.highKey then
        if range.voice.kind == "dummy" then
          return nil
        end
        return range.voice
      end
    end
    return nil
  end
  if instrument.kind == "drum_set" then
    if midiKey < instrument.lowKey or midiKey > instrument.highKey then
      return nil
    end
    local voice = instrument.voices[midiKey - instrument.lowKey + 1]
    if voice.kind == "dummy" then
      return nil
    end
    return voice
  end
  assert(false, "unknown instrument kind")
end

return InstrumentSelector
