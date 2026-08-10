-- Project-owned fixture manifest for the pre-script interaction fallback
-- adapter. Keys are stable identities:
--   object:     map:<mapId>:object:<objectEventId>
--   background: map:<mapId>:background:<eventIndex>
-- Each record maps one source interaction to one static, non-branching
-- dialogue. These are deliberately selected fixtures -- NOT a
-- hand-implemented version of the retail scripts -- so every entry cites the
-- pinned decomp source that justifies the message choice. The runtime never
-- derives a message ID from a script ID; production code only matches these
-- exact keys.
--
-- The scriptId values below are the RAW u16 script IDs from the zone-event
-- records. HGSS stores scr_seq index N + 1 (0 means "no script"); the pinned
-- JSON files list them as `_EV_scr_seq_*_N + 1`. The private test
-- (tests/private/pre_script_interactions_test.lua) validates every key
-- against the compiled maps and pins the background families to the
-- documented raw scriptIds, so a stale fixture fails loudly.
-- Pure data; no love dependency.

return {
  -- Professor Elm's Lab 1F (map 61, message bank 543).
  -- Objects from files/fielddata/eventdata/zone_event/058_T20R0101.json;
  -- scripts from files/fielddata/script/scr_seq/scr_seq_0843_T20R0101.s;
  -- messages from files/msgdata/msg/msg_0543_T20R0101.gmm (names only).
  ["map:61:object:0"] = {
    -- obj_T20R0101_doctor (Elm), scriptId 1 -> scr_seq_T20R0101_000, which
    -- shows msg_0543_T20R0101_00005 when VAR_SCENE_ELMS_LAB == 0. Short,
    -- player-name substitution, no retail branch execution required.
    messageBankId = 543,
    messageId = 5,
    facePlayer = true,
    substitutions = { playerName = "GOLD" },
  },
  ["map:61:object:2"] = {
    -- obj_T20R0101_assistantm (the aide), scriptId 2 -> scr_seq_T20R0101_001,
    -- which shows msg_0543_T20R0101_00018 when VAR_SCENE_ELMS_LAB == 0.
    messageBankId = 543,
    messageId = 18,
    facePlayer = true,
    substitutions = { playerName = "GOLD" },
  },
  -- Background events 0-8 cover scripts 5-9 (raw scriptIds 6-10), each
  -- showing bank 543 messages 93-97 (scr_seq_T20R0101_005..009). Events 0/1
  -- share script 5, 2/3 script 6, 4/5 script 7, 6/7 script 8; one per script
  -- is mapped here. Scripts 93-96 substitute the player name.
  ["map:61:background:0"] = {
    messageBankId = 543,
    messageId = 93,
    facePlayer = false,
    substitutions = { playerName = "GOLD" },
  },
  ["map:61:background:2"] = {
    messageBankId = 543,
    messageId = 94,
    facePlayer = false,
    substitutions = { playerName = "GOLD" },
  },
  ["map:61:background:4"] = {
    messageBankId = 543,
    messageId = 95,
    facePlayer = false,
    substitutions = { playerName = "GOLD" },
  },
  ["map:61:background:6"] = {
    messageBankId = 543,
    messageId = 96,
    facePlayer = false,
    substitutions = { playerName = "GOLD" },
  },
  ["map:61:background:8"] = {
    messageBankId = 543,
    messageId = 97,
    facePlayer = false,
  },
  ["map:61:background:10"] = {
    -- Healing PC: raw scriptId 14 -> scr_seq_T20R0101_013, which shows
    -- msg_0543_T20R0101_00014 before the heal/choice logic (FLAG_GOT_STARTER
    -- unset). Readable fixture message without executing heal/menu logic.
    messageBankId = 543,
    messageId = 14,
    facePlayer = false,
  },
  -- Event 9 (raw scriptId 13) is the starter table (scr_seq_T20R0101_012,
  -- ChooseStarter) and is deliberately unmapped: it mutates story state.

  -- New Bark Town (map 60, message bank 542).
  -- Object from files/fielddata/eventdata/zone_event/057_T20.json; script
  -- from files/fielddata/script/scr_seq/scr_seq_0842_T20.s; message from
  -- files/msgdata/msg/msg_0542_T20.gmm (names only).
  ["map:60:object:1"] = {
    -- obj_T20_gswoman1 (resident), raw scriptId 2 (= scr_seq index 1,
    -- scr_seq_T20_001), which shows msg_0542_T20_00009 when
    -- VAR_SCENE_NEW_BARK_TOWN_OW == 0 (the clean scenario's value).
    -- No substitution needed.
    messageBankId = 542,
    messageId = 9,
    facePlayer = true,
  },
}
