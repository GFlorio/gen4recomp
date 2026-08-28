# Defensive Patterns

This document records hard-won failure classes that recur across the repository. It is not a
generic defensive-programming checklist and should not grow from every isolated bug. Prefer a
code invariant, owning API, static gate, or focused test when those can make a rule mechanical.

Add or strengthen a pattern here when a concrete class of ownership/data-integrity failure is
likely to recur across changes and still requires engineering judgment.

## Acquisition and cleanup

Every acquired resource has exactly one owner. Before acquiring resource N, know who releases
resources 1..N if any later step fails.

- A multi-step constructor/loader cleans up only resources it successfully acquired before
  propagating the original failure.
- Cleanup after failed construction is not recovery. Do not convert programming/corruption
  failures into a half-valid object or plausible success.
- `push`, mount, subscribe, acquire, open, and creating LÖVE Images/Meshes/Canvases change
  ownership and require a matching release path.
- Do not build a generic RAII/transaction helper merely to avoid writing explicit ownership
  for one current operation.

## Objects are usable or construction fails

A normal constructor/factory returns a usable object or fails. Required collaborators remain
required after construction.

Do not return a partial instance whose methods repeatedly ask `if collaborator then`. If
partial availability is a real domain state, represent it explicitly with a state type or
state machine so callers cannot confuse it with a ready object.

## Replacement, protection, and reentrancy

- Replacing owned state disposes the previous state exactly once.
- Stateful subsystems enforce their own busy/reentrancy rule; caller discipline alone is not
  an invariant.
- A boolean `protected`/`pinned` state has one owner. If independent owners genuinely need to
  acquire/release the same protection, use ownership tokens/counting or redesign around a
  single owner. Code must never release protection it did not establish.
- When callbacks can mutate the collection being dispatched, define whether mutation affects
  the current or next dispatch and implement iteration accordingly. Do not leave behavior to
  incidental table iteration.

## Publication and replacement

Never destroy the last known-good artifact/state before the replacement is fully built and
validated.

The default replacement lifecycle is:

1. **stage** new state without disturbing the current published state;
2. **validate** the complete stage;
3. **publish** by transferring the authoritative reference/identity.

A completion marker written last proves completeness; it does not by itself make replacement
transactional.

Ownership changes when publication starts. Before `publish`, the caller may discard its
private disposable stage. Once publication begins, the publisher owns rollback/recovery
material. The caller must not blindly abort/remove the stage after a publish error because it
may now contain the only recoverable copy.

Filesystem wrappers propagate failed write/remove/rename/create operations. A wrapper that
reports success after an underlying persistence failure violates the publication contract.

## Persistent user state and rebuildable state

Persistent user-owned data, especially saves, must not share a deletion root with generated or
rebuildable cache state. Cache invalidation/rebuild operations must be incapable of deleting
user state by construction, not merely by caller convention.

## Shared state and caching

- A cache key includes every property that affects the cached object's immutable runtime
  configuration.
- Do not cache by source path/bytes alone and then mutate the shared result differently for
  different consumers. Either include the configuration in identity or keep per-consumer
  state outside the cached value.
- Builders, sorters, schedulers, and queue constructors keep temporary bookkeeping local; do
  not attach scratch fields to caller-owned or shared objects.
- Derived-cache implementation freshness is owned by the `romdump/src` producer fingerprint.
  Do not add per-compiler version literals just to invalidate implementation changes. Contract
  versions describe persisted formats/APIs; producer source changes are fingerprinted.

## Strict data and intentional recovery

Project-owned current schemas are strict. Missing required arrays/tables and unknown enum/mode
values are errors unless a current producer contract says otherwise.

Before adding a default, alias, compatibility path, or broad recovery branch, identify the
current valid input/caller that requires it. Obsolete development artifacts and incomplete test
fixtures are not compatibility requirements.

Catch only failures the caller can intentionally recover from. A recovery boundary must not
collapse corruption or programmer errors into the same path as an expected operational
failure.

## Review trigger

When code touches one of these classes, review both the successful path and at least one
material failure/sequence path. A high-level failure found here should usually produce the
smallest regression test at the owner that actually violated the contract, not an automatic
new end-to-end journey.
