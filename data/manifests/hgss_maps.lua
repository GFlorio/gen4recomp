-- Semantic HGSS map-header catalog. The raw dump knows only NARC files and
-- member numbers; gameplay needs semantic maps. This mirrors the checked-in
-- manifest approach: non-payload map-header metadata lives in source control.
--
-- Provenance: pret/pokeheartgold @ 1a7f2c301c954df2d19d7f9211529f6decc8dede
--   include/constants/maps.h        (MAP_* -> numeric id)
--   src/data/map_matrix/*, map header tables (member ids, area/event banks)
-- Numeric ids are zero-based ROM ids. Records are immutable by convention.
--
-- expectedMatrixCell / expectedLandDataMemberId are checked-in target assertions
-- the resolver verifies against decoded ROM data; they are never runtime inputs.

return {
  byId = {
    [60] = {
      id = 60,
      symbol = "MAP_NEW_BARK",
      label = "New Bark Town",
      areaDataMemberId = 2,
      moveModelBank = 15,
      matrixMemberId = 0,
      scriptsMemberId = 842,
      scriptHeaderMemberId = 615,
      messageMemberId = 542,
      eventMemberId = 57,
      mapType = "CITY_TOWN",
      cameraType = 0,
      followMode = "ALLOW",
      battleBackground = "GENERAL",
      expectedMatrixCell = { x = 21, z = 12 },
      expectedLandDataMemberId = 0,
    },
    [61] = {
      id = 61,
      symbol = "MAP_NEW_BARK_ELMS_LAB_1F",
      label = "Professor Elm's Lab 1F",
      areaDataMemberId = 25,
      moveModelBank = 15,
      matrixMemberId = 100,
      scriptsMemberId = 843,
      scriptHeaderMemberId = 616,
      messageMemberId = 543,
      eventMemberId = 58,
      mapType = "INTERIOR",
      cameraType = 4,
      followMode = "HEIGHT_RESTRICT",
      battleBackground = "BUILDING_1",
      expectedMatrixCell = { x = 0, z = 0 },
      expectedLandDataMemberId = 244,
    },
  },
  bySymbol = {
    MAP_NEW_BARK = 60,
    MAP_NEW_BARK_ELMS_LAB_1F = 61,
  },
}
