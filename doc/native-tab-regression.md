# Native tab group reconciliation

`manage=tab` opts an application into native tab group handling. The selected
window owns the group's existing BSP entry. Selection replaces the window ID in
that entry in place, preserving split geometry, logical stack order, zoom, and
insertion feedback. Floating state belongs to the group and follows selection.

Previously the first window stayed tiled while selected tabs were excluded from
both tiling and presentation. The ordered-out parent and ordered-in child could
therefore contribute zero displayable windows. Child frame events also returned
before normal tiling correction, and clearing a child's floating flag could not
admit it to the tree while its tab flag remained set.

Group detection now requires Accessibility tab-group evidence. Coincident frames
or an arbitrary same-application window on the same space are insufficient.
Duplicate or ambiguous titles are conservatively left ungrouped. Destruction
reparents all recorded survivors; a selected orphan can recover, and independent
or detached windows retain separate entries. Changing an applied management rule
to `on` or `off` clears existing tab relationships.

Apps such as Fork can recreate a whole workspace while retaining their process.
For opted-in apps, window creation, destruction, and missing-focus recovery also
inspect the application's current AX window list and enqueue undiscovered
windows. This uses the existing serialized creation handler and adds no timer or
polling loop. Presentation selects at most one ordered member per group without
changing managed-space registry policy or either topology provider.

## Verification

`make -C tests` includes group handoff, survivor reparenting, shared floating
state, rule removal, and preservation of stack order, zoom, and insertion state.

`tests/check_native_tabs.sh` is an opt-in real WindowServer/AX regression suite.
Run it on an empty managed BSP space with a running yabai. It compiles a disposable
Cocoa app, adds a labeled `manage=tab` rule, and removes its windows and rule on
exit. It exercises three cycles of selection, shared float/unfloat, independent
same-app windows, parent closure, detachment, frame correction, and workspace
recreation, followed by background-space presentation, application hide/unhide,
and rule replacement. Its bounded waits are test assertions, not daemon polling.

The unmodified signed v27.0.3 release failed at the third-tab handoff: the selected
window retained `is-tab: true`. The signed candidate passed the suite and the
existing `tests/check_window_visibility.sh` retained-window suite on macOS 27.0.1.
Live Fork 2.71.1 checks verified tab selection, float/move/resize/unfloat, and
automatic rediscovery and tiling in both directions of Work/Home workspace
switching without restarting the service. Tests used the compatible scripting
addition provider; its fallback queue stayed empty and it did not own Mission
Control. No topology-provider implementation was changed.
