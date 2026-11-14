# Managed spaces after 27.1.0

Managed topology requires a matching scripting addition. There is no provider
selector, topology bridge, Mission Control automation, request queue or watchdog.
The shared upstream space and window operations remain authoritative. Their
bridged window transfers and gesture-based focus behavior are retained.

## State and ownership

- Desired state: ordered Space UUIDs, names, display affinity, window recovery
  homes, explicit secondary residence and reserved display/workspace UUIDs.
- Observed state: current topology, visibility, group representatives, native
  fullscreen membership and the validity of those observations.
- Pending state: creation purpose/admission receipts, accepted placements awaiting
  observation and active drag ownership. Synchronous calls do not make macOS
  notification delivery synchronous.
- Derived state: consistent presentation and diagnostic data. Query reads never
  select reservations, end secondary residence or change desired placement.

The existing yabai event loop owns policy transitions. managed_space.c handles
lifecycle and intent; managed_space_reconcile.c observes, plans and executes;
managed_space_presentation.c derives queries/signals. There is no second event
bus, thread, polling loop or alternate topology implementation.

## Operations

Enabling validates the exact SA version and required capabilities before managed
mutations. An already-enabled on request refreshes readiness without resnapshotting.
Dock restart invalidates readiness but preserves registry and placement intent.
After successful SA reload, configuration refreshes an already-enabled session.
Ordinary yabai operations keep their original behavior when managed mode is off.

Explicit successful same-display reorder/swap commands update desired managed
order. Cross-display swaps remain shared window transfers. Deletion preserves the
relative order of survivors, renumbers slots and reapplies configured names.
Reconciliation compares desired order within each display, including interleaved
fixed-affinity slots. Labels do not control managed membership.

A repair planner must exclude actual native fullscreen Spaces even if AX flags
lag, defer dragged/unknown/transitional objects, and respect secondary residence.
An attempted transfer is not a completed repair. Re-observe before counting
progress; do not repeat an ineffective action against unchanged state.
Creation admission protects newly created spaces against surplus cleanup until
their purpose and UUID are established; late notifications cannot consume a newer
ticket. Active drag cancellation releases only its owned deferrals.

Window admission and AX reference refresh use shared helpers. Tab representative
handoff updates logical/active stack order, recent history, insertion, feedback,
namespace and drag references together while preserving upstream BSP storage.
Tab grouping continues to require conservative AX evidence.

## Compatibility and migration

Removed configuration: managed_space_topology_backend and all its values.
Removed signal: managed_space_topology_failed. Removed diagnostics: provider,
backend, queue, AX automation, watchdog and Mission Control ownership fields.
The generic managed/stack signals, managed selectors, native fullscreen selectors,
manage=tab, drag settings and enriched query --spaces fields remain.

Scripting-addition readiness and registry diagnostics remain in query
--managed-spaces. Unsupported SA state is a prerequisite error, not an invitation
to launch automation. Existing SIP-compatible upstream features are unaffected.

## Validation

Run make clean-build && make, make -C tests, the managed boundary guard and git
diff --check. tests/check_managed_spaces.sh creates three owned empty Spaces and
checks explicit ordering, deletion, pure diagnostic reads and idempotent refresh.
Retain live native-tab, visibility and multi-display placement suites. Test the
Movist fullscreen transition and SA loss/recovery across a real Dock restart.
Physical display disconnect/reconnect and pointer dragging need corresponding
hardware/input evidence; automated window commands do not establish those cases.
