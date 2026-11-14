# 27.1.0 acceptance

Validation date: 2026-11-14. Host: Apple Silicon, macOS 27.2.1 (26B131),
one connected display and 35 managed UUIDs. Matching scripting addition:
2.1.31-ng.1, capabilities 0x0000005d.

## Candidate

- Universal build and signature verification passed.
- All 56 unit tests, single-SA architectural guard and diff whitespace check passed.
  Coverage includes numeric Space ID widths, interleaved display ordering and
  event-driven retry after a pre-mutation transition refusal.
- Live managed topology passed explicit swap/move desired-order commits, ordered
  deletion, observational query reads and idempotent enabled refresh. All fixture
  Spaces were removed and the original UUID sequence was restored.
- The owned Cocoa fullscreen suite passed three entry/exit cycles, fresh focused
  AX window checks, accurate cached entry/exit state, unchanged registry/home and
  zero namespace repair attempts. Fresh application launch admits its unmanaged
  window through events without a query or readiness refresh changing intent.
  Reapplied rule placement committed its new managed home.
- The supplied video in Movist Pro retained focus after double-clicking into an
  actual native fullscreen Space and after leaving it. Cached fullscreen state
  matched both transitions; namespace repair attempts stayed at zero. The player
  was closed after testing.
- Native tab and retained-window visibility live suites passed. One earlier tab
  run was invalidated by concurrent unit-build cleanup of its fixture directory;
  the valid rerun ran sequentially and passed.
- A Dock restart with reload intentionally withheld suspended managed mutations;
  an explicit create returned an immediate SA error and all desired UUIDs were
  preserved. Loading SA and refreshing on recovered the same registry.
- A second Dock restart recovered through the normal reload/configuration hook.
  The topology suite passed again after recovery.

## Coverage boundaries

Two-display placement, physical pointer dragging and hardware disconnect/reconnect
were not exercised in this run because only one display was connected. Existing
multi-display regression entry points remain available. No fork full-SIP topology
acceptance is required: that implementation has been removed. Shared upstream
bridged window transfer, cross-display swap and gesture focus were preserved in
source and remain protected by the architectural guard.

## Published installation

- [Release workflow 43581668320](https://github.com/olegtarasov/yabai-ng/actions/runs/43581668320)
  succeeded and published the signed universal 27.1.0 asset. Its SHA-256 is
  `2e0f09b069be5bddc1538e9e33f8181d167f35d842ad25df480d4e03cc1b0d57`;
  the installer update and Homebrew tap formula match it.
- Homebrew upgraded to 27.1.0. The running service uses
  `/opt/homebrew/Cellar/yabai-ng/27.1.0/bin/yabai` through the normal Homebrew
  symlink. Its bytes match the published asset and its signature verifies.
- Accessibility authorization matches the published signing requirement at the
  current keg path. The obsolete path grant was removed, the old keg's temporary
  binary replacement was restored, and sudoers matches the published digest.
- The published installation passed managed topology, all three owned fullscreen
  entry/exit cycles, reapplied-rule placement, native-tab and visibility suites.
- Automatic Dock recovery was confirmed by observing the restart event and the
  subsequent enabled-session refresh, then rerunning topology checks. The exact
  SA version and required capabilities were compatible; desired UUIDs survived.
- The supplied Movist video passed double-click native fullscreen and windowed
  return on the published binary: fresh AX focus remained on the player, cached
  fullscreen state matched reality, and namespace repair attempts stayed zero.
- All fixtures were closed and removed. The original 35 managed UUIDs and their
  order were preserved, pending creation/repair counts were zero, and original
  window focus was restored.
