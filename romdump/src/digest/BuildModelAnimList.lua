-- Decoder for one outdoor build-model animation-list record (a member of the
-- exterior_build_anim_list archive, HGSS a/1/0/7). Each record is a fixed
-- 0x18-byte slot: an 8-byte header whose first u16 is 0xFFFF when the model has
-- no animations, followed by a u32 array of resource ids that index the
-- shared build_anim archive (a/1/0/6). Unused id slots are 0xFFFFFFFF.
-- Layout observed from the HGSS field build-model animation list. Pure domain
-- module.
--
-- The header decodes into a source-grounded record -- no byte is thrown away
-- or folded into a vague type. The game's ordinary registrar (ov01_021E8F3C
-- in tmp/refs/pokeheartgold/asm/overlay_01_021E8744.s) and the area loader
-- (AreaDataManager_Load in tmp/refs/pokeheartgold/asm/overlay_01_021FB878.s)
-- read distinct bytes for distinct behaviors:
--   registration (byte 0): the record registers no animation when zero
--     (ov01_021E8F3C: ldrb r0, [r0]; cmp r0, #0; beq -- skip the record)
--   policy (byte 1):       who owns the record. bit 0 (0x01) marks records
--     managed OUTSIDE the ordinary registrar -- door/interaction props --
--     (ov01_021E8864 returns bit 0); bit 1 (0x02) loads the clips without
--     playing them at registration (ov01_021E887C returns bit 1); 0x08 is
--     the time-of-day band special case.
--   control (byte 2):      the animation-object control state
--     (ov01_022044C8 in overlay_01_02204004.c): 0 selects the
--     never-finishing forward loop (-1, 0, 0); nonzero selects the
--     one-shot, not-manager-advanced state (1, 1, 0).
--   areaGate (byte 3):     the area loader skips the ordinary registration
--     entirely when nonzero.
--   reserved / raw6 / raw7 (bytes 4-7): no consumer meaning established yet
--     (the corpus carries nonzero values there); preserved verbatim.
-- decode() returns { ids, registration, policy, control, areaGate, reserved,
-- raw6, raw7, banded }, with banded = (policy == 0x08). The no-animation
-- sentinel (first header u16 0xFFFF) yields empty ids; the byte fields are
-- still exposed.

local BinaryReader = require("libs.codec.src.BinaryReader")

local BuildModelAnimList = {}

local RECORD_SIZE = 0x18
local ID_BASE = 0x08
local NONE = 0xFFFFFFFF
local NO_ANIM = 0xFFFF

-- Source-layout offsets of the header bytes: each behavior consumer reads
-- its own byte, so the decode names them by meaning.
local REGISTRATION_OFFSET = 0
local POLICY_OFFSET = 1
local CONTROL_OFFSET = 2
local AREA_GATE_OFFSET = 3
local RESERVED_OFFSET = 4
local RAW6_OFFSET = 6
local RAW7_OFFSET = 7

-- The time-band policy value: the registrar's bit helpers (ov01_021E8864 /
-- ov01_021E887C) special-case 0x08 to 0/1 -- the banded prop policy.
local BAND_POLICY = 0x08

-- Decode one 0x18-byte record. Returns { ids = { <resourceId>, ... },
-- registration, policy, control, areaGate, reserved, raw6, raw7, banded }
-- (ids empty when the model has no animations; the first header u16 is then
-- 0xFFFF and the byte fields still expose the sentinel bytes).
function BuildModelAnimList.decode(bytes)
  assert(type(bytes) == "string", "BuildModelAnimList.decode requires a string")
  assert(#bytes == RECORD_SIZE, "build-model anim-list record must be " .. RECORD_SIZE .. " bytes, got " .. #bytes)
  local r = BinaryReader.new(bytes, "build-model-anim-list")

  local policy = r:u8(POLICY_OFFSET)
  local ids = {}
  -- The 0xFFFF header marks a model with no animation resources; resource
  -- id 0 is otherwise a valid member of the shared archive.
  if r:u16le(0) ~= NO_ANIM then
    for offset = ID_BASE, RECORD_SIZE - 4, 4 do
      local id = r:u32le(offset)
      if id == NONE then
        break
      end
      ids[#ids + 1] = id
    end
  end
  -- banded is derived from the policy byte, not a raw header field: the game
  -- special-cases 0x08 in its policy-bit helpers.
  return {
    ids = ids,
    registration = r:u8(REGISTRATION_OFFSET),
    policy = policy,
    control = r:u8(CONTROL_OFFSET),
    areaGate = r:u8(AREA_GATE_OFFSET),
    reserved = r:u16le(RESERVED_OFFSET),
    raw6 = r:u8(RAW6_OFFSET),
    raw7 = r:u8(RAW7_OFFSET),
    banded = policy == BAND_POLICY,
  }
end

return BuildModelAnimList
