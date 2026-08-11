-- Deterministic recording adapters for the real field-script host boundaries.
-- They acknowledge effects immediately, while retaining their semantic order.

local RecordingScriptHosts = {}

---@return table { effects: string[], audio: table }
function RecordingScriptHosts.new()
  local effects = {}
  local audio = { current = nil }

  function audio:play(sound)
    self.current = sound
    effects[#effects + 1] = "audio:" .. sound
  end

  function audio:stop(sound)
    if self.current == sound then
      self.current = nil
    end
  end

  function audio:isPlaying()
    return false
  end

  function audio:currentEffect()
    return self.current
  end

  function audio:currentCry()
    return nil
  end

  function audio:currentFanfare()
    return nil
  end

  function audio:playMusic(music)
    effects[#effects + 1] = "music:" .. music
  end

  function audio:stopMusic() end
  function audio:resetMusic() end
  function audio:temporaryMusic() end
  function audio:playCry() end
  function audio:playFanfare() end
  function audio:fadeMusicOut() end
  function audio:fadeMusicIn() end

  return { effects = effects, audio = audio }
end

return RecordingScriptHosts
