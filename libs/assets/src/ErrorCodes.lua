-- The shared structured error codes of the compiled-asset protocol: the
-- codes raised by both the digest compilers (romdump) and the runtime
-- (engine) on malformed compiled data, plus the tests that pin them.
-- Production raises with these named constants and tests assert them, so a
-- rename stays in one place. Codes that live with their owning module stay
-- there (ANIM_CLIP_* on AnimationClip, NSBMD_SBC_* on NsbmdSbcEvaluator);
-- this module owns only the codes whose raise site and consumers cross the
-- package boundary. Pure domain module.

local ErrorCodes = {}

ErrorCodes.SCENE_DESC_EMPTY_MESH = "SCENE_DESC_EMPTY_MESH"
ErrorCodes.SCENE_DESC_BAD_WRAP = "SCENE_DESC_BAD_WRAP"
ErrorCodes.SCENE_DESC_BAD_MATERIALS = "SCENE_DESC_BAD_MATERIALS"
ErrorCodes.SCENE_DESC_CONFLICTING_WRAP = "SCENE_DESC_CONFLICTING_WRAP"
ErrorCodes.POSE_NITRO_SLOT_NOT_FOUND = "POSE_NITRO_SLOT_NOT_FOUND"
ErrorCodes.NSBMD_SBC_NODE_PARENT_MISSING = "NSBMD_SBC_NODE_PARENT_MISSING"

return ErrorCodes
