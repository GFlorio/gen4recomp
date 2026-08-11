# HGSS `GetMenuChoice` (opcode 748)

HeartGold's reachable corpus contains 369 opcode-748 instructions in 239
scripts. Each writes `VAR_SPECIAL_RESULT` and is surrounded by the field
touch-menu hide/show pair. The immediate continuations classify the result as
a two-choice domain: `0` is the default/confirmed choice and `1` is the
alternate/cancel choice. Representative scripts are `0843/012` (starter
confirmation, offset 630), `0947/000` (NPC trade, 34), `0949/000` (photo,
95), and `0953/738` (phone registration, 3579).

The implementation therefore lowers every 748 occurrence to the distinct
`context_choice` request. It is not a `MenuInit`/`MenuExec` builder menu. Its
provider owns only the active two-choice state; the script task owns its
lifetime and writes the selected integer to the raw result variable.
