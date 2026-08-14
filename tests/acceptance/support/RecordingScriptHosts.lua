-- Deterministic recording adapters for the real field-script host boundaries.
-- They acknowledge effects immediately, while retaining their semantic order.

local RecordingScriptHosts = {}

---@return table { effects: string[], audio: table, events: table }
function RecordingScriptHosts.new()
  local effects = {}
  local audio = { current = nil, fadeActive = false }
  local events = { records = {} }

  function audio:play(sound)
    self.current = sound
    effects[#effects + 1] = "audio:" .. sound
  end

  function audio:stop(sound)
    if self.current == sound then
      self.current = nil
    end
  end

  function audio:currentEffect()
    return self.current
  end

  function audio:isEffectPlaying()
    return false
  end

  function audio:isCryFinished()
    return true
  end

  function audio:isFanfarePlaying()
    return false
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

  function audio:isMusicFadeActive()
    return self.fadeActive
  end

  function events:emit(name, payload)
    self.records[#self.records + 1] = { name = name, payload = payload }
  end

  return { effects = effects, audio = audio, events = events }
end

return RecordingScriptHosts
