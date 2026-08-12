-- Vanilla map event bindings : map ids and event
-- keys to stable public script ids, covering every scripted event of New Bark
-- Town and its interiors (maps 60-66 and 384). Map keys are the runtime map
-- header ids; object keys are the runtime actor ids
-- (`map:<mapId>:object:<objectEventId>`, FieldObjectActor.actorId); the exact
-- background array index is stored as provenance and public code
-- uses the stable ids. Events whose raw script id is 0 (no script) are
-- omitted; the type-2 hidden-item background event (map 60 event 4) is
-- omitted because the resolver skips that family. Script ids were resolved
-- during binding generation from the pinned zone-event JSON members (event
-- members 57-63 and 341) against the scr_seq script banks (members 842-849),
-- following the ROM's `script_index + 1` convention.

return {
  maps = {
    -- New Bark Town (map 60, event member 57, script bank 842).
    [60] = {
      objects = {
        ["map:60:object:0"] = "vanilla.hgss.scr_seq.0842.script_000",
        ["map:60:object:1"] = "new_bark.npc.woman_1",
        ["map:60:object:2"] = "vanilla.hgss.scr_seq.0842.script_015",
        ["map:60:object:3"] = "vanilla.hgss.scr_seq.0842.script_005",
        ["map:60:object:4"] = "vanilla.hgss.scr_seq.0842.script_004",
        ["map:60:object:6"] = "vanilla.hgss.scr_seq.0842.script_017",
        ["map:60:object:8"] = "vanilla.hgss.scr_seq.0842.script_004",
        ["map:60:object:9"] = "vanilla.hgss.scr_seq.0842.script_005",
      },
      backgrounds = {
        [0] = "vanilla.hgss.scr_seq.0842.script_013",
        [1] = "vanilla.hgss.scr_seq.0842.script_007",
        [2] = "vanilla.hgss.scr_seq.0842.script_014",
        [3] = "vanilla.hgss.scr_seq.0842.script_016",
      },
    },

    -- Elm's Lab 1F (map 61, event member 58, script bank 843).
    [61] = {
      objects = {
        ["map:61:object:0"] = "elms_lab.elm",
        ["map:61:object:2"] = "vanilla.hgss.scr_seq.0843.script_002",
      },
      backgrounds = {
        [0] = "vanilla.hgss.scr_seq.0843.script_005",
        [1] = "vanilla.hgss.scr_seq.0843.script_005",
        [2] = "vanilla.hgss.scr_seq.0843.script_006",
        [3] = "vanilla.hgss.scr_seq.0843.script_006",
        [4] = "vanilla.hgss.scr_seq.0843.script_007",
        [5] = "vanilla.hgss.scr_seq.0843.script_007",
        [6] = "vanilla.hgss.scr_seq.0843.script_008",
        [7] = "vanilla.hgss.scr_seq.0843.script_008",
        [8] = "new_bark.lab_sign",
        [9] = "vanilla.hgss.scr_seq.0843.script_012",
        [10] = "vanilla.hgss.scr_seq.0843.script_013",
      },
    },

    -- Elm's Lab 2F (map 62, event member 59, script bank 844).
    [62] = {
      objects = {
        ["map:62:object:0"] = "vanilla.hgss.scr_seq.0844.script_000",
        ["map:62:object:1"] = "vanilla.hgss.scr_seq.0844.script_001",
      },
      backgrounds = {},
    },

    -- Player House 1F (map 63, event member 60, script bank 845).
    [63] = {
      objects = {
        ["map:63:object:0"] = "vanilla.hgss.scr_seq.0845.script_001",
      },
      backgrounds = {
        [0] = "vanilla.hgss.scr_seq.0845.script_002",
        [1] = "vanilla.hgss.scr_seq.0845.script_002",
        [2] = "vanilla.hgss.scr_seq.0845.script_004",
        [3] = "vanilla.hgss.scr_seq.0845.script_003",
        [4] = "vanilla.hgss.scr_seq.0845.script_005",
      },
    },

    -- Player House 2F (map 64, event member 61, script bank 846).
    [64] = {
      objects = {},
      backgrounds = {
        [0] = "vanilla.hgss.scr_seq.0846.script_000",
        [1] = "vanilla.hgss.scr_seq.0846.script_001",
      },
    },

    -- Southwest House (map 65, event member 62, script bank 847).
    [65] = {
      objects = {
        ["map:65:object:0"] = "vanilla.hgss.scr_seq.0847.script_000",
      },
      backgrounds = {},
    },

    -- Rival House 1F (map 66, event member 63, script bank 848).
    [66] = {
      objects = {
        ["map:66:object:0"] = "vanilla.hgss.scr_seq.0848.script_000",
      },
      backgrounds = {},
    },

    -- Rival House 2F (map 384, event member 341, script bank 849).
    [384] = {
      objects = {
        ["map:384:object:0"] = "vanilla.hgss.scr_seq.0849.script_000",
        ["map:384:object:1"] = "vanilla.hgss.scr_seq.0849.script_001",
      },
      backgrounds = {
        [0] = "vanilla.hgss.scr_seq.0849.script_003",
        [1] = "vanilla.hgss.scr_seq.0849.script_004",
      },
    },
  },
}
