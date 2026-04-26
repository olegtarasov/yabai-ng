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
  the desired managed set in Mission Control order. If `managed_space_names` is
  configured, yabai first ensures enough normal spaces exist, snapshots only the
  first configured-name count, and reconciles any additional normal spaces away.
- Managed identity is the space UUID, not its label. Labels remain normal yabai
  UI/config metadata.
- Managed slot names are runtime config. Numeric names are exposed in queries
  only; non-numeric names are also applied as ordinary yabai labels.
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

- `yabai -m config managed_space_names <comma-separated names>`
  Sets optional managed slot names. Example:
  `1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z`.

- `yabai -m query --managed-spaces`
  Returns managed registry/debug state.

- `yabai -m query --spaces`
  Includes `is-managed`, `managed-order`, `managed-name`,
  `displayable-window-count`, `displayable-windows`, and `displayable-apps`
  fields for consumers that want managed-space and native fullscreen
  presentation data without a separate window query.

- `managed_spaces_changed`
  Signal emitted after the derived managed-space or native fullscreen
  presentation state changes.

- `managed_space_focused`
  Signal emitted when the active managed or native fullscreen space changes.

## Validation

Run the relevant checks before handing work back:

- `make clean-build && make`
- `make -C tests`
- `git diff --check`

For runtime changes, validate with a local yabai instance before recommending
installation or service restart.

## Release Checklist

When asked to cut a new `yabai-ng` release:

- Update `CHANGELOG.md` with a new `## [X.Y.Z] - YYYY-MM-DD` entry.
- Confirm the default `VERSION` in `makefile` and the fallback version in
  `src/yabai.c` match the release when appropriate.
- Run `make clean-build && make`, `make -C tests`, and `git diff --check`.
- Confirm GitHub secrets exist for `YABAI_CERT_P12_BASE64`,
  `YABAI_CERT_PASSWORD`, and `HOMEBREW_TAP_DEPLOY_KEY`.
- Commit and push `master` before tagging.
- Create an annotated tag with `git tag -a vX.Y.Z -m "Release vX.Y.Z"`.
- Push the tag with `git push origin vX.Y.Z` and watch the release workflow.
- Verify the GitHub release asset, installer hash update, and
  `olegtarasov/homebrew-tap` formula update.

## Commit Checkpoints

Create a git commit when a task is finished or when you reach a risky
checkpoint that may need rollback later. Use small, descriptive imperative
commit messages.
