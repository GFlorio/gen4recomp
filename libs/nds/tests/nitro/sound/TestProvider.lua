-- Test-only normalized sound provider for NDS player tests.

local TestProvider = {}

---@param bundle table
---@return table
function TestProvider.new(bundle)
  assert(bundle and bundle.index and bundle.sequences and bundle.banks and bundle.samples and bundle.sampleMetadata)
  return {
    sequence = function(_, id)
      return assert(bundle.sequences[id])
    end,
    bank = function(_, id)
      return assert(bundle.banks[id])
    end,
    player = function(_, id)
      return assert(bundle.index.players[id])
    end,
    loadSample = function(_, key)
      return {
        metadata = assert(bundle.sampleMetadata[key]),
        pcm = assert(bundle.samples[key]),
      }
    end,
  }
end

return TestProvider
