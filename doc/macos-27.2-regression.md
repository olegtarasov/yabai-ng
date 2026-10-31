# macOS 27.2 scripting-addition acceptance

Validated on macOS 27.2, build 26B123, Apple Silicon loading the arm64e Dock
slice, for yabai-ng 27.0.5. The original 27.0.4 payload reported zero lookup
bits and acknowledged space focus without changing the desktop.

## Compatibility changes

The Dock's functions moved before the old scan starts. Both arm64e slices now
resolve exactly one match per required lookup. `currentSpaceForDisplayUUID:`
was replaced by `currentSpaceForDisplay:`, which takes a display id obtained
from `displayForSPID:`. The old selector is retained when available.

On 27.2, WallpaperAgent replaces the old desktop-picture manager. Space moves
now use `SLSMoveManagedSpaceToDisplayIndex`, followed by the Dock's Swift
space-moved report handler, on the main queue. The handler receives the
controller through `swift_context` and the destination UUID as a Swift String.
Preconditions reject a stale destination or a move leaving no normal source
space. Other supported macOS versions keep their existing movement path.

The exact-version handshake must include all platform-required bits: `0x5d`
on Apple Silicon 27.2, `0x7f` on other supported platforms. The removed wallpaper
manager and unused window-focus function are excluded only on 27.2 and later.
The raw lookup mask remains visible in queries; missing movement support still
rejects the primary provider. No fallback-provider logic or adapter changed.

References used to identify and adapt the replacement interfaces:

- https://github.com/asmvik/yabai/issues/2802
- https://github.com/asmvik/yabai/issues/2832
- https://github.com/LCS-Dev-Ergos/Yabai/commit/7aec949a58626ae61c134cefce905248569baff4
- https://github.com/LCS-Dev-Ergos/Yabai/commit/4da5636

## Checks

- Clean payload regeneration and universal daemon build: passed.
- `make -C tests`: 52 passed, including platform capability requirements.
- `tests/check_managed_space_provider_boundary.sh`: passed.
- `tests/check_osax_patterns.sh`: passed, five unique matches in each slice.
- Live primary handshake: `2.1.31-ng.1`, capabilities `0x0000005d`.
- Managed focus in both directions: passed.
- Create, reorder in both directions, destroy a disposable space: passed;
  original 35 managed spaces restored, queue idle, Mission Control unowned.
- Dock restart: primary provider remained selected, queue idle and Mission
  Control unowned; focus worked after reloading the payload.
- SketchyBar signal integration: an empty focused space appeared highlighted
  and disappeared after leaving it.
- Real disposable-window transfer, opacity, stacking sub-layer, sticky and
  floating toggles: passed.
- Native fullscreen entry/query and exit: passed.
- `tests/check_window_visibility.sh`: passed.
- `tests/check_native_tabs.sh`: passed.
- Config shell and Lua syntax: passed; no config changes required.

## Coverage limits

Only one physical display was connected: actual cross-display movement remains
unexercised, though same-display reorder exercised the new Swift move handler.
The arm64e.x1 slice was checked statically, not executed. No full-SIP host was
available; fallback selection/serialization remains covered by unit tests.
Computer Use's synthetic app-directed keypress did not exercise skhd's global
event tap, so physical keyboard and bar-pointer input are separate from the
verified commands, signal delivery and bar query state.

Upstream master dd84572 (including v7.1.25) was already an ancestor; fetching
upstream and merging reported no new work.
