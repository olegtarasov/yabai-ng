# Managed Spaces Main Display Migration Diagnostics

Date: 2026-05-23

Status: diagnostic, design proposal, and implementation record. The plan below
has been implemented in this changeset; the original diagnostic evidence is
kept because it explains the architectural reason for the fix.

## Problem

Reproduction:

1. Start yabai with only the built-in display connected.
2. Enable managed spaces from config and work normally.
3. Connect an external display and make it the macOS main display.
4. Expected: yabai-ng managed spaces move to the new main display.
5. Actual: managed spaces stay on the built-in display.

This is a real architectural mismatch in the current managed-space subsystem. The
current code models each managed slot as sticky to a preferred display UUID. It
does not model "follow the macOS main display" as a first-class target.

## Live Evidence

Read-only live checks were run against the currently running service:

```sh
command -v yabai
yabai --version
pgrep -fl yabai
launchctl print gui/$(id -u)/com.asmvik.yabai
```

Result summary:

- Active binary: `/opt/homebrew/bin/yabai`
- Version: `yabai-v26.1.1`
- Running service: `com.asmvik.yabai`, pid `49610`
- Service program: `/opt/homebrew/bin/yabai`

The current macOS main display is CG display id `4`:

```sh
osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); $.CGMainDisplayID()'
```

`yabai -m query --displays` shows:

- CG display id `4`, arrangement index `1`, frame `1920x1080`, spaces `[1, 2]`
- CG display id `1`, arrangement index `2`, frame `1728x1117`, spaces `[3..36]`

`yabai -m query --managed-spaces` summarized by current display and preferred
display:

```json
{
  "enabled": true,
  "counts": {
    "managed": 35,
    "extra": 0,
    "repaired": 0
  },
  "by_display": [
    { "display": 1, "count": 1, "orders": [1] },
    { "display": 2, "count": 34, "orders": [2, 3, 4, "...", 35] }
  ],
  "by_preferred_display": [
    { "preferred_display": 1, "count": 1, "orders": [1] },
    { "preferred_display": 2, "count": 34, "orders": [2, 3, 4, "...", 35] }
  ]
}
```

Important distinction: the managed-space query reports display arrangement
indexes, not CG display ids. In this live state, arrangement display `1` is the
external main display, and arrangement display `2` is the built-in display.

This matches the bug:

- the external display is currently the macOS main display,
- only one managed slot is on it,
- 34 managed slots still prefer and occupy the built-in display.

The single managed slot on the external display is not evidence of main-display
migration. It is produced by the current "ensure every active display has at
least one managed space" coverage rule.

## Code Findings

### Managed entries pin a preferred display

`src/managed_space.h` stores `preferred_display_uuid` on every managed entry:

```c
struct managed_space_entry
{
    CFStringRef uuid;
    CFStringRef preferred_display_uuid;
    uint64_t sid;
    int order;
    char *name;
    char *label;
};
```

`src/managed_space.c` assigns that preferred display when a managed entry is
created:

- `managed_space_add_entry()` gets the space UUID.
- It sets `entry.preferred_display_uuid = display_uuid(space_display_id(sid))`.
- Enabling managed mode snapshots current user spaces and calls
  `managed_space_add_entry()` for each selected space.

So when yabai starts with only the built-in display, every managed entry is
born with the built-in display as its preferred display.

### Reconciliation moves spaces back to preferred displays first

`managed_space_reconcile()` runs this order:

1. `managed_space_move_preferred_spaces_back()`
2. `managed_space_ensure_display_coverage()`
3. `managed_space_recreate_missing_space()`
4. window repair during topology grace
5. extra-space cleanup

`managed_space_move_preferred_spaces_back()` is decisive:

```c
uint32_t preferred_did = display_id(entry->preferred_display_uuid);
if (!preferred_did) continue;

uint32_t current_did = space_display_id(entry->sid);
if (current_did == preferred_did) continue;

space_manager_move_space_to_display(&g_space_manager, entry->sid, preferred_did);
```

That means reconnecting an external display and changing the macOS main display
does not change the managed target. If a managed slot prefers the built-in
display, the reconciler treats being on the built-in display as correct.

### Only explicit `space --display` updates a managed slot display

The only command path that changes a managed entry's preferred display is
`space --display`:

- `src/message.c` calls `space_manager_move_space_to_display(...)`.
- On success it calls
  `managed_space_note_user_space_display_changed(&g_managed_space, acting_sid, selector.did)`.
- That hook updates the entry with `managed_space_set_preferred_display(entry, did)`.

Display topology changes do not call this hook.

### Main-display changes are not represented

The CoreGraphics SDK has `kCGDisplaySetMainFlag`.

The current display reconfiguration handler only posts add, remove, moved, and
desktop-shape-changed events:

```c
if (flags & kCGDisplayAddFlag) {
    event_loop_post(&g_event_loop, DISPLAY_ADDED, ...);
} else if (flags & kCGDisplayRemoveFlag) {
    event_loop_post(&g_event_loop, DISPLAY_REMOVED, ...);
} else if (flags & kCGDisplayMovedFlag) {
    event_loop_post(&g_event_loop, DISPLAY_MOVED, ...);
} else if (flags & kCGDisplayDesktopShapeChangedFlag) {
    event_loop_post(&g_event_loop, DISPLAY_RESIZED, ...);
}
```

There is no event for "the macOS main display changed".

The existing `DISPLAY_CHANGED` event is different. It comes from
`NSWorkspaceActiveDisplayDidChangeNotification` and updates the active menu-bar
display / focused display state. It is not a `CGMainDisplayID()` change event.

### Current coverage logic works against the expected behavior

`managed_space_ensure_display_coverage()` intentionally enforces at least one
managed space on every active display:

```c
if (managed_space_display_has_managed_user_space(ms, did)) continue;
...
space_manager_move_space_to_display(&g_space_manager, donor->sid, did);
...
donor->preferred_display_uuid = target_uuid ? CFRetain(target_uuid) : NULL;
```

This explains the live state:

- the new external main display got one donor managed space,
- the donor's preferred display was changed to the external display,
- all other managed spaces kept their original built-in preference.

The current architecture is a per-display-affinity model, not a main-display
model.

### Moving every managed space off the old display has a hard constraint

`space_manager_move_space_to_display()` refuses to move the last normal user
space off a display:

```c
bool last_space = space_manager_is_space_last_user_space(sid);
if (last_space) return SPACE_OP_ERROR_INVALID_SRC;
```

This is correct for macOS "Displays have separate Spaces": every connected
display needs at least one normal user space. Therefore a real fix cannot simply
retarget all managed entries to the new main display and call the existing move
helper in a loop. The final managed space on the old display would not move.

To make "all managed spaces live on main" true, yabai-ng must intentionally keep
one unmanaged placeholder user space on each active non-main display. Current
managed mode cleans up all unmanaged normal spaces as extras, so this also
requires changing the cleanup contract.

## Root Cause

The root cause is a missing concept: managed spaces need a display target policy.

Today each managed space has a concrete `preferred_display_uuid`, and the
reconciler treats that UUID as authoritative until a user runs `space --display`.
When yabai starts on the built-in display only, that concrete preferred display
is the built-in UUID. Connecting an external display and making it the macOS
main display does not alter those UUIDs, and the event loop does not surface
`kCGDisplaySetMainFlag` anyway.

The visible symptom is not a one-line event bug. A correct fix must update the
managed-space display model, reconciliation, placeholder handling, and docs.

## Proposed Solution

### 1. Add explicit managed display affinity

Extend `struct managed_space_entry` with an affinity mode:

```c
enum managed_space_display_affinity {
    MANAGED_SPACE_DISPLAY_FOLLOW_MAIN,
    MANAGED_SPACE_DISPLAY_FIXED,
};
```

For each entry:

- `FOLLOW_MAIN` means the effective target display is `CGMainDisplayID()` /
  `display_manager_main_display_uuid()`.
- `FIXED` means the effective target display is the entry's stored display UUID.

Keep `preferred-display` query fields as the effective target display for
compatibility, and add a debug field such as:

```json
"display-affinity": "follow-main" | "fixed"
```

Recommended default semantics:

- Managed entries created by `managed_space_names` bootstrap follow the main
  display.
- Managed entries captured while enabling managed mode follow main by default.
  A later explicit `space --display` command can convert an individual entry to
  fixed affinity.
- `space --display` marks that entry as `FIXED`, because it is an explicit user
  request to target a concrete display selector.
- `space --create` while managed mode is on should record whether the create was
  targeted explicitly. If it was created on a non-main display, make it `FIXED`.
  If it was created as part of managed-name bootstrap, make it `FOLLOW_MAIN`.

If preserving the current sticky-display behavior for some workflows is
important, this should become a config option such as:

```sh
yabai -m config managed_space_display_policy follow-main
yabai -m config managed_space_display_policy fixed
```

For this fork's named managed-space workflow, `follow-main` should be the
default because it matches the reported expectation.

### 2. Track main-display changes as an event-driven input

Do not add polling.

Update `display_handler()` to notice `kCGDisplaySetMainFlag`. The current
`else if` chain also means a multi-flag callback can swallow later flags, so the
handler should process relevant flags independently or explicitly post a
coalesced internal topology event.

Add an internal event such as:

```c
EVENT_TYPE_ENTRY(DISPLAY_MAIN_CHANGED)
```

Handler responsibilities:

- update a cached main-display UUID, or let managed space compare current main
  against its cached value,
- mark spaces invalid where main-display-dependent layout matters
  (`external_bar main` is one known example),
- call a managed-space hook such as
  `managed_space_note_display_configuration_changed(&g_managed_space)`,
- request a managed reconciliation pass.

Also call the same managed-space main-display check from existing topology
events:

- display added,
- display removed,
- display moved,
- display resized,
- Dock restarted,
- system woke.

This keeps the model event-driven while making it robust to macOS delivering
display add and set-main in varying order.

### 3. Compute an effective target display per managed slot

Replace direct reads of `entry->preferred_display_uuid` inside reconciliation
with a helper:

```c
static CFStringRef managed_space_target_display_uuid(struct managed_space *ms,
                                                     struct managed_space_entry *entry);
```

Rules:

- `FOLLOW_MAIN`: return the current main display UUID.
- `FIXED`: return the stored fixed display UUID.
- If a fixed display is absent, keep topology grace and do not rewrite the
  fixed UUID to the fallback display. That preserves return-to-external behavior
  after a display is reconnected.

Rename the internal reconciler step from "move preferred spaces back" to
"move spaces to target displays" to make the semantics clear.

### 4. Replace display coverage with target coverage

The current `managed_space_ensure_display_coverage()` is the wrong invariant for
follow-main behavior. It should not move a managed donor to every active display.

New invariant:

- every active display that has at least one managed entry targeting it should
  eventually have those managed entries present,
- displays with no managed entries targeting them should not receive a managed
  donor just for coverage,
- active non-main displays still need one normal user space, but that space
  should be an unmanaged placeholder.

This preserves explicit fixed-display slots without forcing all displays to own
a managed slot.

### 5. Add required unmanaged placeholders for non-main displays

Before moving the last managed space away from a non-main display, ensure that
display has a normal unmanaged placeholder user space.

Needed mechanics:

- Add a helper to find unmanaged normal spaces on a display.
- Add a helper to decide if a display requires a placeholder:
  - active display,
  - not the current main display,
  - no managed entry targets that display,
  - moving managed spaces away would otherwise leave no normal user space.
- Create the placeholder with `space_manager_add_space()` using a normal user
  space on that display as the acting space.
- Track pending placeholder creates by display UUID so reconciliation does not
  issue duplicate creates while waiting for `SLS_SPACE_CREATED`.
- Do not increment `pending_user_creates`; placeholders must not be added to the
  managed set.

Cleanup must learn about placeholders:

- Preserve exactly one required unmanaged placeholder per active non-main
  display.
- If that placeholder contains windows, move those windows to the nearest or
  most appropriate managed space, but keep the placeholder itself.
- Destroy additional unmanaged normal spaces as before.
- Change `extra-space-count` to count cleanup candidates, not required
  placeholders. Optionally add `placeholder-space-count` to `query --managed-spaces`.

This is the piece that makes the fix architecturally complete. Without it, the
last managed space on the old display cannot move.

### 6. Preserve managed identity and window repair behavior

Managed identity must remain the space UUID. The proposed display-affinity
change does not alter that.

Moving a space to another display should preserve the managed entry UUID and
therefore preserve the remembered window namespace. Existing window repair can
continue to repair windows by managed-space UUID after topology grace.

Native fullscreen spaces remain exempt:

- never retarget them,
- never destroy them,
- do not use them as placeholders,
- do not count them as satisfying the normal user-space placeholder requirement.

### 7. Keep the public runtime surface honest

Docs should be updated to say:

- managed spaces follow the macOS main display by default,
- explicit `space --display` pins that managed slot to the target display,
- yabai-ng may keep one unmanaged placeholder normal space on each active
  non-main display because macOS requires a normal user space there,
- native fullscreen spaces are still exempt.

Update both:

- `doc/yabai.asciidoc`
- generated `doc/yabai.1`

If a display policy config is added, document it and include it in the release
notes.

## Review Rounds

### Review 1: naive retargeting is not enough

Naive idea:

- when `CGMainDisplayID()` changes, rewrite every `preferred_display_uuid` to
  the new main display.

Problems:

- It loses legitimate fixed-display choices.
- It breaks return-to-external behavior after a display was temporarily absent.
- It still cannot move the final managed space off the old display because
  `space_manager_move_space_to_display()` rejects the last user space.
- It does not address `managed_space_ensure_display_coverage()`, which would
  move a donor managed space back onto secondary displays.

Design correction:

- introduce follow-main vs fixed affinity,
- preserve fixed absent-display UUIDs,
- replace display coverage with target coverage,
- add unmanaged placeholders for secondary displays.

### Review 2: main-display event alone is too narrow

Naive idea:

- just handle `kCGDisplaySetMainFlag`.

Problems:

- Display add and set-main can arrive together, and the current `else if` chain
  can swallow flags.
- Main display can effectively change around wake, Dock restart, display add,
  or display removal.
- The active-display `DISPLAY_CHANGED` path is not the same as main-display
  state.

Design correction:

- add a main-display change event,
- make the display callback process flags without dropping multi-flag cases,
- compare cached main UUID on all existing topology events,
- keep reconciliation coalesced through the existing event loop.

### Review 3: placeholders must not become unmanaged clutter

Naive idea:

- create an unmanaged placeholder and exempt it from cleanup.

Problems:

- If the user or macOS opens windows on it, it is no longer an empty placeholder.
- If creation is asynchronous, repeated reconciliation passes can create
  duplicates.
- If `extra-space-count` includes required placeholders, the managed-state query
  looks perpetually dirty.

Design correction:

- track pending placeholder creates by display UUID,
- preserve one required placeholder per non-main display,
- move windows off a placeholder during cleanup but keep the placeholder,
- exclude required placeholders from `extra-space-count` or add a dedicated
  placeholder counter.

## Implementation Summary

The implemented fix follows this design:

- managed entries now have `display-affinity` of `follow-main` or `fixed`,
- `managed_space_display_policy` defaults new managed entries to `follow-main`,
- explicit `space --display` pins the moved managed slot to `fixed`,
- explicit non-main `space --create --display` creates a fixed managed slot,
- CoreGraphics `kCGDisplaySetMainFlag` posts an internal main-display topology
  event,
- reconciliation moves managed spaces to their effective target display instead
  of enforcing one managed donor per active display,
- one required unmanaged placeholder normal space is preserved on each active
  non-main display with no managed target,
- `query --managed-spaces` reports display policy, per-slot display affinity,
  and placeholder count.

## Validation Plan

Static checks:

```sh
make clean-build && make
make -C tests
git diff --check
```

Targeted tests to add:

- pure helper tests for follow-main vs fixed target selection,
- tests that `space --display` converts a managed slot to fixed affinity,
- tests that main-display changes retarget only follow-main slots,
- tests that fixed absent display UUIDs are not rewritten,
- tests that required placeholders are not counted as cleanup extras,
- tests that unmanaged placeholder windows are moved out while the placeholder
  remains.

Live validation:

1. Start yabai with only the built-in display connected.
2. Enable:
   ```sh
   yabai -m config managed_space_names 1,2,3,4,5,6,7,8,9,A,B,C,D,E,F,G,H,I,J,K,L,M,N,O,P,Q,R,S,T,U,V,W,X,Y,Z
   yabai -m config managed_spaces on
   ```
3. Open windows across several managed spaces.
4. Connect the external display and set it as macOS main.
5. Verify:
   ```sh
   yabai -m query --managed-spaces
   yabai -m query --spaces
   yabai -m query --displays
   ```
6. Expected:
   - all managed slots with `display-affinity == "follow-main"` target the
     external main display,
   - fixed slots remain on their fixed active displays,
   - non-main displays keep one unmanaged normal placeholder when needed,
   - no native fullscreen space is moved or destroyed,
   - `managed_spaces_changed` fires after the presentation changes.

Disconnect/reconnect validation:

1. With managed slots on the external main display, disconnect the external
   display.
2. Verify managed slots remain usable on the built-in display while fixed
   external affinities are not rewritten away.
3. Reconnect the external display and make it main again.
4. Verify follow-main slots return to the external main display and fixed
   external slots return to the external display.

Manual affinity validation:

1. Move one managed slot with `yabai -m space --display <secondary-display>`.
2. Change the macOS main display.
3. Verify that slot remains fixed to the explicit display while follow-main
   slots migrate.

## Baseline Checks Already Run

These checks were run before writing this report, on the unmodified source:

```sh
make clean-build && make
make -C tests
git diff --check
```

Results:

- `make clean-build && make`: passed.
- `make -C tests`: passed, 16/16 tests succeeded. The build emitted existing
  macOS 15 CoreVideo deprecation warnings for `CVDisplayLink*`.
- `git diff --check`: passed.

## Post-Implementation Validation

Static validation:

- `make clean-build && make`: passed.
- `make -C tests`: passed, 20/20 tests succeeded. The build emitted existing
  macOS 15 CoreVideo deprecation warnings for `CVDisplayLink*`.
- `make man`: passed and regenerated `doc/yabai.1`.
- `git diff --check`: passed.

Live validation:

- The local service uses `/opt/homebrew/bin/yabai`, which is a symlink to this
  checkout's `bin/yabai`.
- After rebuilding, the binary had to be signed with `make sign` before launchd
  would grant Accessibility access.
- Restarting the service with the first implementation exposed a real issue:
  macOS created the placeholder candidate on the active main display, leaving
  one follow-main managed space stuck on the secondary display. The fix was
  revised so placeholder reconciliation first moves an existing empty unmanaged
  spare to the secondary display before creating another space.
- After the revised build was signed and the service restarted, live query
  state was:
  - `managed-space-display-policy`: `follow-main`
  - `managed-space-count`: `35`
  - `extra-space-count`: `0`
  - `placeholder-space-count`: `1`
  - off-target managed spaces: `0`
  - display affinity counts: `35` `follow-main`

This validates the reported scenario on the current machine: all managed slots
target and occupy the macOS main display, while the secondary display keeps one
unmanaged empty normal placeholder.

## Implementation Boundary

Do not implement this as an external Sketchybar or shell-script workaround. The
state being corrected is internal yabai managed-space topology. The fix belongs
primarily in:

- `src/managed_space.h`
- `src/managed_space.c`

Expected small hook points:

- `src/display.c` for `kCGDisplaySetMainFlag`,
- `src/event_loop.h` and `src/event_loop.c` for an internal main-display event,
- `src/message.c` to mark `space --display` and user-created spaces with the
  correct affinity,
- `src/view.c` only if query serialization needs new fields through existing
  space query output,
- docs and tests.

The solution should not add polling loops or timers. It should remain
event-driven and coalesced through the existing reconciliation event path.
