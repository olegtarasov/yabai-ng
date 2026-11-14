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
  on that display so macOS keeps the display space namespace alive. This space
  is a usable tiled workspace, reserved by display and space UUID. Do not
  evacuate its windows or consume it as a missing managed slot's replacement.
- Intentional window drops and window commands commit their destination. A
  window parked on the reserved secondary workspace retains its prior managed
  home for recovery if that workspace disappears; reconnecting does not move
  the recovered window back automatically. Active drags defer only their own
  namespace repair and cache updates, and release deferred work through events.
- Native fullscreen spaces are exempt. Managed mode must not move or destroy
  them.
- Reconciliation is event-driven only. Do not add polling loops or timers unless
  the user explicitly accepts that tradeoff.
- Do not hardcode Sketchybar or any other bar integration in yabai. Expose
  queries and signals; let user config decide how to consume them.

## Managed Topology Boundary

Managed topology requires a compatible scripting addition. There is one
synchronous implementation: the authoritative upstream space_manager operations.
Do not add alternate providers, Mission Control automation, request queues,
watchdogs, fallback input taps, or SIP-on topology support.

- Keep managed policy in fork-owned files. space_manager must not import it.
- Preserve upstream bridged window transfers, gesture-based space focus, core
  Mission Control observation, and the macOS compatibility fixes for those paths.
- Validate the exact scripting-addition version and platform-required capability
  bits before enabling managed mode. Missing support returns an immediate error.
- Runtime loss of the scripting addition preserves desired UUIDs and intent,
  suspends automatic mutations, and exposes readiness diagnostics. Reapplying
  managed_spaces on refreshes readiness without resnapshotting an enabled session.
- Space creation notifications and bridged window transfers can arrive after a
  synchronous call. Preserve creation ownership, late-event receipts, and accepted
  placement intent; do not confuse delayed observation with a failed operation.
- Native fullscreen membership excludes namespace repair independently of cached
  Accessibility flags. Unknown/transitional observations defer mutation.
- Reconciliation must stop when an operation makes no observed progress. Attempted
  moves are not completed repairs. Continue through relevant events, not timers.
- Queries and presentation derivation must not change registry, reservations, or
  placement intent. Diagnostic reads are observational.
- Successful explicit reorder commands update desired order. Deletion preserves
  surviving relative order. Cross-display swaps remain shared window transfers.

Run tests/check_managed_space_provider_boundary.sh for topology changes. Acceptance
requires a real matching scripting-addition run, synchronous commands, no topology
UI automation, and loss/recovery across a Dock restart without losing UUIDs.

## Fork Surface

- src/managed_space.c and src/managed_space.h: lifecycle, readiness, registry,
  display affinity, explicit command/placement intent, and creation admission.
- src/managed_space_reconcile.c: observation, bounded planning and execution
  through shared upstream helpers.
- src/managed_space_presentation.c: consistent query/signal projection.
- src/native_tab.*: evidence-based tab groups and representative handoff.
- Small integration hooks in manifest, message, event_loop, event_signal, view,
  window_manager, and mouse_handler. Preserve upstream layout storage and APIs.

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
all platform-required capability bits present before restarting the yabai
service.

For runtime changes, validate with a local yabai instance before recommending
installation or service restart.

## Development Host and Iteration

- Use the fastest useful local feedback loop. Build and run local test versions
  before publishing; a release round trip is not required for testing.
- You may temporarily replace the installed Homebrew binary or its symlink with
  a local build, install a test scripting addition, and restart affected
  services to validate changes on the development host.
- The user authorizes changes to the development host needed for this work,
  including system files, signing, permissions, sudoers rules, installations,
  and service configuration. Proceed autonomously within the task's scope;
  do not request routine confirmation for these changes. Follow any explicit
  user limits and higher-priority requirements.
- Always clean up stale system permissions associated with this setup. Remove
  grants for obsolete binary paths, retired signing identities, and temporary
  test installations once they are no longer needed. Keep only permissions
  required by the current installation and active development work; preserve
  unrelated applications' permissions.
- After testing, remove temporary fixtures and restore the user's desktop
  state. After a release, leave the published Homebrew installation active,
  with current permissions and sudoers digests, rather than a local test build.

## Upstream Merge Playbook

When merging a new upstream release tag:

- Start clean, run `git fetch upstream --tags --prune`, and identify the latest
  upstream release from `git ls-remote --tags --sort=-v:refname upstream 'v*'`.
  Compare `git merge-base HEAD <tag>` and review both
  `git diff <merge-base>..<tag>` and `git diff <merge-base>..HEAD` before
  resolving conflicts.
- Preserve the fork release surface unless explicitly cutting a new `yabai-ng`
  release. In conflicts, keep fork defaults in `src/yabai.c` (fork fallback
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

Every completed fix to yabai code defaults to a patch-version bump and a full
`yabai-ng` release, without waiting for the user to request either. Configuration
or documentation-only changes do not trigger this default. Explicit user
instructions take priority, including skipping a release or choosing a minor
version bump instead.

For every release:

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
- Update the development host from the published repository through Homebrew.
  Confirm the active executable resolves to the published Homebrew version,
  not a temporary local build.
- Load the matching scripting addition, refresh required permissions and
  sudoers digests, and remove stale permissions from previous installations
  and temporary test builds.
- Restart affected services and validate the installed published version with
  live smoke tests for the changed behavior and relevant existing integrations.
  A successful release workflow or local-build test alone is not completion.

## Commit Checkpoints

Create a git commit when a task is finished or when you reach a risky
checkpoint that may need rollback later. Use small, descriptive imperative
commit messages.
