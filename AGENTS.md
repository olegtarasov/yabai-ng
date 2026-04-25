# yabai-ng Fork Guide

## Purpose

This repository is a personal fork of upstream yabai. The fork exists to move
macOS space reconciliation into yabai itself while keeping the upstream merge
surface small and explicit.

Managed spaces are a fork-owned subsystem. Upstream files should only contain
small, obvious hooks into that subsystem; substantial behavior belongs in
`src/managed_space.h` and `src/managed_space.c`.

## Architecture Rules

- Preserve upstream mergeability. Keep fork logic in separate files whenever
  possible.
- Managed mode is off by default and enabled with:
  `yabai -m config managed_spaces on`
- Turning managed mode on snapshots the current non-fullscreen user spaces as
  the desired managed set in Mission Control order.
- Managed identity is the space UUID, not its label. Labels remain normal yabai
  UI/config metadata.
- `space --label` must not change managed membership.
- `space --create` while managed mode is on intentionally adds the newly
  created user space to the managed set.
- `space --destroy` through yabai intentionally removes the destroyed managed
  space from the managed set after the operation succeeds.
- Native fullscreen spaces are exempt. Managed mode must not move or destroy
  them.
- Reconciliation is event-driven only. Do not add polling loops or timers unless
  the user explicitly accepts that tradeoff.
- Do not hardcode Sketchybar or any other bar integration in yabai. Expose
  queries and signals; let user config decide how to consume them.

## Fork Surface

- `src/managed_space.h`
  Public managed-space subsystem types and hooks.

- `src/managed_space.c`
  Managed registry, display affinity, window namespace cache, coalesced
  reconciler, query serialization, and signal counters.

- Small hook points in:
  `src/manifest.m`, `src/yabai.c`, `src/message.c`, `src/event_loop.*`,
  `src/event_signal.*`, and `src/view.*`.

## Runtime Surface

- `yabai -m config managed_spaces on|off`
  Enables or disables managed mode. Enabling snapshots current user spaces.

- `yabai -m query --managed-spaces`
  Returns managed registry/debug state.

- `yabai -m query --spaces`
  Includes `is-managed` and `managed-order` fields.

- `managed_spaces_changed`
  Signal emitted after managed topology or namespace state changes.

## Validation

Run the relevant checks before handing work back:

- `make clean-build && make`
- `make -C tests`
- `git diff --check`

For runtime changes, validate with a local yabai instance before recommending
installation or service restart.

## Commit Checkpoints

Create a git commit when a task is finished or when you reach a risky
checkpoint that may need rollback later. Use small, descriptive imperative
commit messages.
