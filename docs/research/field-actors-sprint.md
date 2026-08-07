# Field Actors, Interaction, and Dialogue Foundation — Sprint Notes

Specification: `tmp/spec.md` (revision 1). Implementation targets the working
tree on top of integration commit `27c826d` ("game: first pass on message
engine"), the state after Epics 1–7 landed. Epics 9–10 land on top of that
tree (working tree includes the dialogue/UI work of Epic 8).

- Integration commit: `27c826d`
- Entry gate (§3.1): predecessor milestone checks pass (normal `FieldState`
  boot, 60 Hz `FieldSession`, maps 60/61 through `FieldMapLoader`, camera
  paths, terrain/collision, warp round trip).
- Predecessor save/resume at the integration point: schema `g4-field-save-v1`
  existed with round-trip tests; saving event state and the avatar was Epic 11
  and was still blocked at sprint start — Epic 8 deliberately does not add a
  second save system (`FieldSave.canCapture` now also refuses while the
  dialogue is modal). Epic 11 extended the schema with event flags/vars and
  the avatar. Since there are no players yet, the extension replaced the old
  schema in place and now carries the plain name `g4-field-save-v1`: there is
  exactly one schema, no version history, and a resumed save owns flags/vars
  and avatar while the demo scenario seeds only a fresh boot.

## Epic status

| Epic | Status |
| --- | --- |
| 1 Actor graphics spike + ADR | done (`docs/adr/field-actor-visual-representation.md`) |
| 2 Actor visual compiler/cache | done |
| 3 Event state + actor lifecycle | done |
| 4 Actor rendering + player visual | done |
| 5 Dynamic occupancy | done |
| 6 Message and font extraction | done |
| 7 Message provider and layout | done |
| 8 Dialogue controller + UI renderer | done |
| 9 Interaction resolver | done |
| 10 Pre-script adapter | done |
| 11 Save and resume | done |
| 12 Hardening + handoff | pending |

Per-epic facts, contract decisions, and verification live in `tmp/notes.md`
(top of file = newest work).
