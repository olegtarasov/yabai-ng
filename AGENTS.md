# yabai-ng Fork Guide

## Purpose

This repository is a personal fork of upstream yabai. The fork exists to move
macOS space reconciliation into yabai itself while keeping the upstream merge
surface small and explicit.

Managed spaces are a fork-owned subsystem. Upstream files should only contain
small, obvious hooks into that subsystem; substantial behavior belongs in
the fork-owned managed-space files.

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
- Managed slots follow the macOS main display by default. Fixed display
  affinity is explicit runtime state and targets concrete display UUIDs.
- `space --label` must not change managed membership.
- `space --create` while managed mode is on intentionally adds the newly
  created user space to the managed set. Explicit non-main display creates are
  fixed; ordinary creates inherit `managed_space_display_policy`.
- `space --destroy` through yabai intentionally removes the destroyed managed
  space from the managed set after the operation succeeds.
- `space --display` through yabai intentionally pins the moved managed space to
  fixed display affinity.
- If all managed spaces leave an active non-main display, managed-space
  reconciliation may create and preserve one unmanaged placeholder normal space
  on that display so macOS keeps the display space namespace alive.
- Native fullscreen spaces are exempt. Managed mode must not move or destroy
  them.
- Reconciliation is event-driven only. Do not add polling loops or timers unless
  the user explicitly accepts that tradeoff.
- Do not hardcode Sketchybar or any other bar integration in yabai. Expose
  queries and signals; let user config decide how to consume them.

## Managed Topology Provider Boundary

Managed topology has two deliberately separate implementations:

- The `scripting-addition` provider is the legacy, synchronous implementation
  for hosts where the matching scripting addition is available. Its observable
  behavior is frozen to commit `7b67591`: validation order, private-API call
  order, return codes, command timing, reconciliation timing, and managed
  metadata semantics must remain unchanged.
- The `sip-safe` provider is the asynchronous implementation for full-SIP
  hosts. It owns SkyLight bridge validation, Mission Control Accessibility
  automation, serialization, watchdogs, rollback, UI ownership, and
  asynchronous metadata transactions.

`src/managed_space_topology.*` is only the provider-selection and dispatch
facade. In `auto` mode it performs one scripting-addition handshake when managed
mode is enabled. An exact version with all capability bits selects the legacy
provider; any other result selects the SIP-safe provider. The result is sticky
for that managed-mode session. A Dock restart or operation failure must never
switch providers implicitly. Reapplying the backend policy is the explicit
refresh mechanism.

Keep this boundary mechanically enforceable:

- `src/space_manager.*` must not import or reference managed-space provider
  code. Its legacy topology functions remain the authoritative synchronous
  implementation.
- `src/managed_space_legacy.*` must stay a transparent adapter over those
  functions. Do not add provider validation, fallback, queueing, retries, or
  metadata policy there.
- `src/managed_space_sip_safe.*` must not be called directly outside the
  provider facade, its completion hooks, and its failure-signal serializer.
- Never fall through from a selected legacy operation to SIP-safe automation,
  or from a selected SIP-safe operation to the scripting addition. Backend
  fallback inside SIP-safe is limited to validated bridge-to-Accessibility
  fallback before mutation begins.
- AX observers, CoreDock notifications, topology bridge lookup, watchdogs,
  request queues, Mission Control ownership, and input monitoring are SIP-safe
  resources. Do not initialize them for the legacy provider.
- Input monitoring required by SIP-safe operations must use a transient tap
  owned by the SIP-safe session. Do not expand yabai's permanent mouse event
  mask with keyboard or unrelated mouse events.
- Safe-only limits, errors, retry state, async metadata commits, and query state
  must not change legacy call sequences or leak into `enum space_op_error`.
- Provider-independent registry and reconciliation policy remains in
  `src/managed_space.c`. Every branch needed only for queued SIP-safe execution
  must be guarded by `managed_space_topology_uses_sip_safe`.

Run `tests/check_managed_space_provider_boundary.sh` for every topology change.
In addition to unit tests, acceptance requires both a full-SIP SIP-safe run and
a real compatible-scripting-addition run. The latter must verify synchronous
commands, an idle SIP-safe queue, no Mission Control ownership, and no provider
switch after a Dock restart.

## Fork Surface

- `src/managed_space.h`
  Public managed-space subsystem types and hooks.

- `src/managed_space.c`
  Managed registry, display affinity, window namespace cache, coalesced
  reconciler, query serialization, and signal counters.

- `src/managed_space_topology.h` and `src/managed_space_topology.m`
  Provider selection, sticky session policy, result translation, and dispatch.

- `src/managed_space_legacy.h` and `src/managed_space_legacy.c`
  Transparent adapter to the pre-SIP-safe synchronous scripting-addition path.

- `src/managed_space_sip_safe.h` and `src/managed_space_sip_safe.m`
  Serialized full-SIP bridge and Mission Control Accessibility implementation.

- Small hook points in:
  `src/manifest.m`, `src/yabai.c`, `src/message.c`, `src/event_loop.*`,
  `src/event_signal.*`, and `src/view.*`.

## Runtime Surface

- `yabai -m config managed_spaces on|off`
  Enables or disables managed mode. Enabling snapshots current user spaces.

- `yabai -m config managed_space_names <comma-separated names>`
  Sets optional managed slot names. Example:
  `1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z`.

- `yabai -m config managed_space_display_policy follow-main|fixed`
  Sets the default managed-space display affinity. `follow-main` is the
  default; `fixed` preserves current concrete display UUIDs.

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

- `managed_space_topology_failed`
  Signal emitted for an asynchronous SIP-safe topology failure.

## Validation

Run the relevant checks before handing work back:

- `make clean-build && make`
- `make -C tests`
- `tests/check_managed_space_provider_boundary.sh`
- `git diff --check`

When upstream changes `src/osax/common.h`, `src/osax/arm64_payload.m`, or
`src/osax/x64_payload.m`, run `make clean` before rebuilding. `make clean-build`
does not remove the generated `src/osax/payload_bin.c`, so it can otherwise
embed a stale scripting-addition payload whose version differs from the host
binary. After such a rebuild, uninstall and reinstall the scripting addition,
load it, and verify that its handshake reports the current `OSAX_VERSION` with
all capability bits present before restarting the yabai service.

For runtime changes, validate with a local yabai instance before recommending
installation or service restart.

## Upstream Merge Playbook

When merging a new upstream release tag:

- Start clean, run `git fetch upstream --tags --prune`, and identify the latest
  upstream release from `git ls-remote --tags --sort=-v:refname upstream 'v*'`.
  Compare `git merge-base HEAD <tag>` and review both
  `git diff <merge-base>..<tag>` and `git diff <merge-base>..HEAD` before
  resolving conflicts.
- Preserve the fork release surface unless explicitly cutting a new `yabai-ng`
  release. In conflicts, keep fork defaults in `src/yabai.c` (`26.x.y` fallback
  version), `makefile`, and `scripts/install.sh` (`olegtarasov/yabai-ng`, fork
  archive name, fork hash). Do not replace these with upstream `7.x.y` values.
- Keep fork changelog entries above the upstream history, but add the upstream
  release entry and update the upstream comparison links so the base tag is the
  newly merged upstream tag.
- For docs, accept upstream behavioral text changes while preserving fork-added
  commands, config keys, query fields, and signals. Keep `doc/yabai.asciidoc`
  and the generated `doc/yabai.1` in sync; date-only manpage conflicts usually
  take the upstream release date unless regenerating docs for a fork release.
- When upstream changes shared helpers such as `space_manager_move_window*`,
  apply those fixes in the shared helper instead of adding fork-specific bypasses
  so managed spaces, stack movement, rules, swaps, and ordinary commands all use
  the same corrected path.
- Re-check hook files carefully: `src/manifest.m`, `src/yabai.c`,
  `src/message.c`, `src/event_loop.*`, `src/event_signal.*`, `src/view.*`,
  `src/space_manager.*`, and `src/window_manager.*`. Preserve fork hooks and
  imports while incorporating upstream private-API declarations and init code.
- For the v7.1.25-style bridged window-management change, keep the weakly found
  `SLSPerformAsynchronousBridgedWindowManagementOperation` symbol, Objective-C
  runtime include, and bridged move operation in the shared space move helpers;
  also keep upstream's `SLSSpaceSetFrontPSN` after sending a window to another
  space.
- If an upstream merge changes scripting-addition versioning or architecture
  payload sources, use `make clean`, not only `make clean-build`, so the
  generated embedded payload is regenerated before building and installing.
- After resolving, search conflict-prone files for leftover conflict markers,
  inspect `git diff --check`, then run `make clean-build && make` and
  `make -C tests`. If runtime behavior changed, smoke-test a local yabai before
  recommending installation or service restart.

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
