-- Private target test: the real animated model descriptors of a map with
-- animated buildings encode to G4M3 through the production mesh contract.
-- The digest emits dynamic batches without skin attributes (rigid Nitro
-- geometry), so MeshWriter.ensureSkinAttributes stamps the rigid form
-- before the loader's g4m3 encode; a door transition into New Bark crashed
-- with MESH_MISSING_SKIN_ATTRIBUTES before this was enforced. Runs only
-- via --test-private.

local Assert = require("tests.support.Assert")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MeshWriter = require("libs.assets.src.MeshWriter")
local SceneMesh = require("libs.engine.src.SceneMesh")

local T = {}

-- The scene loader's G4M3 assembly for one batch, run headlessly: stamp the
-- rigid attributes, encode, decode, and return the decoded skin arrays.
local function encodeDynamicBatch(batch)
  MeshWriter.ensureSkinAttributes(batch.vertices)
  local bytes = MeshWriter.encode(batch, { format = "g4m3" })
  local decoded = assert(SceneMesh.decode(bytes))
  return decoded
end

function T.new_bark_animated_descriptors_encode_to_rigid_g4m3(romFs)
  local bundle = assert(MapAssetCompiler.compile(romFs, "MAP_NEW_BARK"))
  local animatedCount = 0
  for _, desc in pairs(bundle.models) do
    if desc.dynamic then
      animatedCount = animatedCount + 1
      for _, mesh in ipairs(desc.dynamic.batches) do
        local decoded = encodeDynamicBatch(mesh.batch)
        assert(decoded.joints and decoded.weights, "the G4M3 decode carries skin arrays")
        for i = 1, #decoded.vertices do
          Assert.deepEqual(decoded.joints[i], { 0, 0, 0, 0 }, "rigid vertex carries zero joint indices")
          Assert.deepEqual(decoded.weights[i], { 0, 0, 0, 0 }, "rigid vertex carries zero weights")
        end
      end
    end
  end
  Assert.isTrue(animatedCount > 0, "New Bark carries animated models (its doors)")
end

return T
