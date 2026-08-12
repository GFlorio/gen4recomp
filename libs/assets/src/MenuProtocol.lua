-- The project-owned list-menu protocol constants. Script lowering (romdump),
-- the script menu host, and menu layout all consume this contract, so the
-- source-bound values live in one place. HGSS list-menu protocol facts from
-- pret/pokeheartgold's scrcmd.c and list_menu.c; public semantic menus do not
-- expose them.
-- STANDARD_MESSAGE_BANK is the standard list-menu bank (0xBF): the scr_seq
-- corpus's menu_add message ids (up to 475, e.g. 321/322/323 for the mart's
-- BUY/SELL/SEE YA! items) resolve there; tests/rom verifies the pin against
-- the imported ROM.

local MenuProtocol = {}

MenuProtocol.STANDARD_MESSAGE_BANK = 191
MenuProtocol.CANCEL_RESULT = 0xFFFE
MenuProtocol.BOTTOM_SCREEN_TILE_PLACEMENT = "hgss_bottom_screen_tiles"

return MenuProtocol
