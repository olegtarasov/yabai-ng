# Retained-window tiling regression

## Diagnosis

Reproduced on macOS 27.0.1 (26A434) with Safari Settings. This establishes the
failure on that build; it does not establish which macOS release introduced it.

Window lifetime, WindowServer order state, and Accessibility element lifetime
are separate. Safari retains the Settings WindowServer ID when closing the
window. Closing orders it out without destroying the tracked window. Reopening
orders the same ID in, and can supply a different Accessibility element.

Yabai subscribed to WindowServer notification 808 for order feedback and
presentation, but not the separate order-in (815) and order-out (816)
notifications. Its tiling membership followed AX creation/destruction and
space validation. A closed retained window therefore kept its BSP leaf; a
reopened window previously removed by validation did not regain a leaf.
The cached AX element could also leave frame writes targeting an obsolete
element even after the tree was repaired.

Switching spaces invokes `window_manager_validate_and_check_for_windows_on_space`
and flushes the resulting tree. That explains why a round trip repaired both
opening and closing symptoms.

## Repair

- Subscribe to 815/816 on macOS 15, 26, and 27, where the existing per-window
  subscription already covers tracked windows. Keep the original 808 behavior.
- Deliver visibility changes to the serialized event loop by window ID. Reject
  windows already invalidated by an AX destruction callback.
- Re-read current ordered state rather than trusting a potentially stale queued
  edge. Remove an ordered-out window from tiling while keeping it tracked.
- On readmission, obtain its current AX element from the application, replace
  obsolete observation registrations, and use the shared space-manager tiling
  helper. Preserve floating rules and manual floating.
- Leave hide/minimize and native-tab ownership to their existing handlers. Skip
  native fullscreen and Mission Control transitions. No timers or polling are
  added to yabai, and no topology-provider dispatch is changed.
- Publish managed presentation from the same visibility event.

## Validation

`tests/check_window_visibility.sh` builds a disposable Cocoa application and
exercises real WindowServer/AX delivery against the running yabai. Run it from
an empty BSP space; it refuses an occupied space. `YABAI_BIN` can select another
client executable. It opens only fixture windows and terminates the fixture on
exit. Its bounded waits are test assertions, not daemon reconciliation polling.

The test covers five retained-ID order-out/order-in cycles, background window
visibility, queued transitions, manual floating, minimize/deminimize,
application hide/unhide, destruction, and subsequent creation. Fixture command
acknowledgments prevent assertions from passing before the operation executes.

The unmodified signed v27.0.2 release build failed the first retained order-out
assertion: the main window remained 954 points wide. The signed candidate passed
the complete suite. Repeated real Safari checks verified a 1912-point main
window when Settings was closed, then a 954-point main window at x=4 and
Settings at x=962 when reopened, without switching spaces. Logs confirmed AX
element replacement for the same Settings ID (13952).

The existing 47 tests and provider-boundary check also passed. Local runtime
checks used the compatible scripting-addition provider (2.1.30, capabilities
0x7f), an empty fallback queue, and no Mission Control ownership. Older macOS
versions and a full-SIP machine were not available for runtime testing.
