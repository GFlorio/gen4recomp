-- The project-owned deterministic pre-script scenario. It seeds which target
-- object events start hidden so the field runtime has a stable, readable
-- population before any script engine exists. Objects are named by stable
-- map/object identity; FieldScenario resolves each to the ROM's numeric event
-- flag, so nothing here hardcodes a flag number.
--
-- This is NOT retail new-game initialization and must not be read as story
-- progression: it hides the story-guarded actors (rival, friend, Marill,
-- photographer, and the variable-sprite duplicates) and leaves the residents and
-- the two laboratory interaction targets visible. Spawn tile and facing stay in
-- data/manifests/target_map_anchors.lua; this file owns visibility only.
-- Pure data; no love dependency.

return {
  id = "pre-script-demo-v1",

  visibility = {
    -- Professor Elm's Lab 1F (map 61). Object 0 (Elm) and object 2 (the aide)
    -- stay visible as the interaction targets; the officer and the
    -- variable-sprite friend are story actors and start hidden.
    { op = "set_object_event_flag", mapId = 61, objectEventId = 1 },
    { op = "set_object_event_flag", mapId = 61, objectEventId = 3 },

    -- New Bark Town (map 60). Every flag-guarded object starts hidden, leaving
    -- the always-visible residents (objects 1, 2, and 5) to populate the town.
    { op = "set_object_event_flag", mapId = 60, objectEventId = 0 },
    { op = "set_object_event_flag", mapId = 60, objectEventId = 3 },
    { op = "set_object_event_flag", mapId = 60, objectEventId = 4 },
    { op = "set_object_event_flag", mapId = 60, objectEventId = 6 },
    { op = "set_object_event_flag", mapId = 60, objectEventId = 7 },
    { op = "set_object_event_flag", mapId = 60, objectEventId = 8 },
    -- Objects 8 and 9 share event flag 744; setting it once hides both, but
    -- both are listed so the manifest states the full intent.
    { op = "set_object_event_flag", mapId = 60, objectEventId = 9 },
  },
}
