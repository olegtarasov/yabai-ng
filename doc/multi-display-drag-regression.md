# Cross-display tiled-window placement

Upstream yabai already chooses the display under the pointer for tiled-window
drag previews and drops. Managed reconciliation introduced two competing
policies: repairing a transient cross-space move to its remembered UUID, and
evacuating windows from the secondary display's required unmanaged placeholder.
The old mouse-up path also did not record a deliberately accepted destination.

The repair treats an active drag as transient, commits accepted placement for
all affected tiles, and lets a reserved secondary workspace hold windows.
Secondary residence is recorded separately from the managed recovery home.
Disconnecting the secondary display restores a previously managed window to
that home; reconnecting does not automatically send it back. Workspace identity
uses display and space UUIDs, including while replacing missing managed slots.
Native fullscreen remains exempt, and the topology-provider boundary is retained.

`tests/check_multi_display_drag.sh` is an opt-in live check against a running
yabai. It requires an empty managed BSP source and another display containing
one empty, visible, unmanaged normal BSP space. It creates a temporary exact-app
rule and its own disposable Cocoa windows while preserving topology and user
windows. The rule enables native tabs for the fixture. Cleanup closes the
fixture, removes that rule, and restores the original focused window or space.

Run from the repository root:

```sh
SOURCE_SPACE=4 tests/check_multi_display_drag.sh
# Optional explicit client and destination display:
SOURCE_SPACE=4 TARGET_DISPLAY=2 YABAI_BIN=/opt/homebrew/bin/yabai \
  tests/check_multi_display_drag.sh
```

The automated path checks `window --space` and `window --display` in both
directions, secondary residence and recovery-home bookkeeping, placement through
real creation/destruction reconciliation events, native-tab group movement and
selection, tab detachment, stable secondary UUID, unchanged managed registry,
and idle drag/provider state. Its bounded waits are test assertions; they do not
add polling to the daemon. Failure output includes a task-owned diagnostics
directory under `tests/bin/`.

For actual title-bar dragging and visual preview acceptance:

```sh
SOURCE_SPACE=4 tests/check_multi_display_drag.sh --manual
```

The script prints the fixture window ID and waits for two physical drags:
source to the empty secondary workspace, then back to the populated source.
The anchor is minimized for the first drag so the source starts as a full-width
tile, including when the destination display is smaller; it is restored before
the return drag.
Hold each drag long enough to inspect the preview before releasing. The first
preview should cover the empty display's available tiling area; the return
preview should follow the existing target tile's insertion zone. The script
requires an observed nonzero drag count followed by mouse release and the
expected resulting space. The timeout defaults to 120 seconds per drag and can
be adjusted with `MANUAL_TIMEOUT_SECONDS`.

No mouse or keyboard input is synthesized. App-directed computer-use input may
bypass yabai's global event tap; a floating-window control that also fails to
move is an invalid input test, not a passed drag check. The automated placement
suite does not establish pointer delivery, flicker-free tracking, or visual
preview correctness. Those require the manual phase and direct observation.

Run candidate acceptance with the compatible scripting-addition provider and
repeat the applicable checks on a real full-SIP host before claiming fallback
acceptance. For primary topology acceptance, also verify synchronous commands,
an idle fallback queue, no Mission Control ownership, and a sticky provider
after a Dock restart. Disconnect/reconnect and recovery of windows first created
on the secondary workspace require separate physical-display acceptance.

## Acceptance record

Local candidate checks on 2026-11-05 used macOS 27.2 (26B123), Apple Silicon,
with a 1920x1080 main display and a 1728x1117 secondary display. The compatible
scripting addition reported `2.1.31-ng.1` and capabilities `0x0000005d`.

- Universal build, provider-boundary check, and `git diff --check`: passed.
- Unit suite: 71 passed, including per-window deferral, UUID reservation,
  delayed transfers, native-tab handoff/group movement, feedback lifecycle,
  create ownership, and fallback failure cleanup.
- Automated multi-display placement suite with the primary provider: passed.
- Existing native-tab and window-visibility live suites: passed.
- Multi-display placement with `sip-fallback` explicitly selected locally:
  passed; this does not establish full-SIP acceptance.
- Synchronous primary create/focus/destroy before and after a real Dock restart:
  passed. Automatic scripting-addition reload recovered operations; provider
  selection stayed primary, the fallback queue stayed idle, and Mission
  Control remained unowned. The original 35 managed UUIDs were restored.

The first candidate's native-tab live check caught inactive tab IDs remaining
on the source space. The corrected shared window-transfer path moves validated
group members together; repeating the suite passed tab selection in both
directions and independent movement after detachment.

The physical fixture was prepared, including a full-width source tile, but no
physical input was observed and the waiting attempt was closed. Pointer
delivery, visual preview, and flicker-free tracking remain unverified until a
separate physical check is performed. Published-package results are recorded
after release.
Actual hardware disconnect/reconnect has not been exercised. A real full-SIP
host was unavailable; the owner explicitly accepted releasing with that check
unverified. Forced fallback on this SIP-disabled host is reported separately.
