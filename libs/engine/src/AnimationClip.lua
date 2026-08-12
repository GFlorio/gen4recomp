-- AnimationClip: the nitro clip record the field runtime and the digest
-- share. A clip is the smallest unit gameplay and the player know: it has a
-- frame count, a category (joint or material), a free-form kind, and a list
-- of tracks that bindings map onto a concrete model. Everything below
-- `source` is opaque to the runtime: the compiled payload (the `compiled`
-- table the Nitro clip compilers emit) owns the curve semantics, and the
-- runtime never decodes `source` -- it is carried for diagnostics,
-- content-addressing, and modding tooling only.
--
--   clip = {
--     id = "a106-12",              unique clip identifier
--     name = "door_op",            source-format name (the Nitro dict entry)
--     category = "joint"|"material",
--     kind = "trs"|"pattern"|"color"|...,   free-form, never dispatched on
--     frameCount = 8,              number of frames (last key frame + 1)
--     tracks = { { target = t, targetIndex = i }, ... },
--     semanticNames = { "door.open" },  optional engine-level animation roles
--     source = { type = "nitro", ... },  opaque provenance
--     compiled = ...,              the compiled Nitro payload (compilers)
--   }
--
-- Track targets are the keys a binding maps onto model elements: joint
-- tracks target a node index, material tracks a material name. Channels are
-- opaque to the clip contract -- Nitro clips sample through their compiled
-- payload, so a track needs only its target. Track tables are retained by
-- reference and never mutated. Pure domain module.

local Errors = require("libs.rom.src.Errors")

local AnimationClip = {}

-- Fixed-point frame unit: one frame is FRAME_UNIT, shared by every player
-- and sampler in the animation runtime (DS fixed point is 1.M.12).
AnimationClip.FRAME_UNIT = 4096

-- The category vocabulary is joint and material: no field visibility
-- animation exists (the corpus has no NSBVA members and the format was
-- deleted), so a clip claiming the visibility category is rejected.
AnimationClip.CATEGORIES = { joint = true, material = true }

-- The semantic animation roles gameplay and the digest share: the one owner
-- for the door open/close vocabulary -- MapPropAnimCompiler stamps the roles
-- onto compiled clips and MapDoor addresses them by role, so the strings have
-- exactly one home on the animation contract.
AnimationClip.ROLES = {
  DOOR_OPEN = "door.open",
  DOOR_CLOSE = "door.close",
}

-- Validate one track: a target is required; anything else (channels, curve
-- shapes) is opaque to the clip contract and left to the compiled payload.
local function validateTracks(tracks, context)
  for i, track in ipairs(tracks) do
    if track.target == nil then
      Errors.raise(
        "ANIM_CLIP_TRACK_NO_TARGET",
        "track " .. i .. " of clip " .. context .. " has no target",
        { track = i }
      )
    end
  end
end

-- Build a validated clip from a plain data table. Raises a structured error
-- on any contract violation. Track tables are kept by reference; the clip
-- never writes to caller-owned data.
function AnimationClip.new(data)
  assert(type(data) == "table", "AnimationClip.new requires a table")
  if not AnimationClip.CATEGORIES[data.category] then
    Errors.raise(
      "ANIM_CLIP_BAD_CATEGORY",
      "clip category must be joint or material, got " .. tostring(data.category),
      {}
    )
  end
  if type(data.id) ~= "string" or #data.id == 0 then
    Errors.raise("ANIM_CLIP_NO_ID", "clip requires a non-empty id", {})
  end
  if type(data.name) ~= "string" or #data.name == 0 then
    Errors.raise("ANIM_CLIP_NO_NAME", "clip requires a non-empty name", {})
  end
  if
    not (type(data.frameCount) == "number" and data.frameCount >= 1 and math.floor(data.frameCount) == data.frameCount)
  then
    Errors.raise(
      "ANIM_CLIP_BAD_FRAME_COUNT",
      "clip frame count must be a positive integer, got " .. tostring(data.frameCount),
      {}
    )
  end
  if type(data.tracks) ~= "table" or #data.tracks == 0 then
    Errors.raise("ANIM_CLIP_NO_TRACKS", "clip " .. data.id .. " has no tracks", {})
  end
  if data.source ~= nil and type(data.source) ~= "table" then
    Errors.raise("ANIM_CLIP_BAD_SOURCE", "clip source must be a table or nil", {})
  end
  if data.semanticNames ~= nil then
    assert(type(data.semanticNames) == "table", "semanticNames must be a table")
    for _, name in ipairs(data.semanticNames) do
      assert(type(name) == "string" and #name > 0, "semantic names must be non-empty strings")
    end
  end

  validateTracks(data.tracks, data.id)

  return {
    id = data.id,
    name = data.name,
    category = data.category,
    kind = data.kind,
    frameCount = data.frameCount,
    tracks = data.tracks,
    semanticNames = data.semanticNames or {},
    source = data.source,
  }
end

return AnimationClip
