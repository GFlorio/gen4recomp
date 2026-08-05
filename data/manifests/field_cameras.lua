-- Per-version discovery facts for the HGSS field-camera table in ARM9 overlay
-- 1. Pointer offsets come from the western overlay assembly; the RAM address is
-- an assertion after pointer discovery, never the lookup mechanism.

local common = {
  cpu = "arm9",
  overlayId = 1,
  pointerFileOffsets = { 0x532C, 0x547C },
  recordCount = 17,
  recordSize = 0x24,
  expectedTableRamAddress = 0x02206478,
}

return {
  heartgold = common,
  soulsilver = common,
}
