-- HGSS list-menu protocol values from pret/pokeheartgold's scrcmd.c and
-- list_menu.c. Imported script lowering and runtime presentation share these
-- source-bound values; public semantic menus do not expose them.
-- STANDARD_MESSAGE_BANK is the standard list-menu bank (0xBF): the scr_seq
-- corpus's menu_add message ids (up to 475, e.g. 321/322/323 for the mart's
-- BUY/SELL/SEE YA! items) resolve there; tests/rom verifies the pin against
-- the imported ROM.

return {
  STANDARD_MESSAGE_BANK = 191,
  CANCEL_RESULT = 0xFFFE,
  BOTTOM_SCREEN_TILE_PLACEMENT = "hgss_bottom_screen_tiles",
}
