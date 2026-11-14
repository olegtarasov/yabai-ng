#!/bin/sh
# Managed topology uses the shared synchronous scripting-addition operations.
# Keep the historical filename so existing validation entry points still work.
set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

for removed_module in managed_space_topology managed_space_scripting_addition managed_space_sip_fallback; do
    for extension in c h m; do
        if [ -e "$repository_root/src/$removed_module.$extension" ]; then
            echo "removed managed topology implementation remains: $removed_module.$extension" >&2
            exit 1
        fi
    done
done

if grep -Eq 'managed_space|MANAGED_SPACE' "$repository_root/src/space_manager.c" \
    "$repository_root/src/space_manager.h"; then
    echo "shared space operations import managed-space policy" >&2
    exit 1
fi

if grep -Eq 'SPACE_OP_ERROR_(QUEUED|LIMIT_REACHED|ACCESSIBILITY|TOPOLOGY_BACKEND)' \
    "$repository_root/src/space_manager.h"; then
    echo "removed provider errors leaked into shared space operations" >&2
    exit 1
fi

if grep -En 'managed_space_(topology|sip_fallback)|MANAGED_SPACE_TOPOLOGY|CoreDock|AXObserver|CGEventTap|SLSBridged' \
    "$repository_root"/src/managed_space* \
    "$repository_root/src/message.c" \
    "$repository_root/src/event_loop.h" \
    "$repository_root/src/event_signal.h"; then
    echo "alternate topology backend or its resources returned to managed spaces" >&2
    exit 1
fi

if grep -REn 'managed_space_(topology|sip_fallback)|MANAGED_SPACE_TOPOLOGY' \
    "$repository_root/src" "$repository_root/tests/src"; then
    echo "removed topology API or event hook returned" >&2
    exit 1
fi

if grep -En 'dispatch_after|usleep\(|sleep\(' "$repository_root"/src/managed_space*; then
    echo "managed reconciliation acquired timer or polling machinery" >&2
    exit 1
fi

if grep -Eq 'kCGEvent(KeyDown|FlagsChanged)' "$repository_root/src/mouse_handler.h"; then
    echo "topology input monitoring leaked into the permanent mouse event mask" >&2
    exit 1
fi

# These are upstream functionality, not the removed managed-topology bridge.
for upstream_window_helper in space_manager_move_window_to_space space_manager_move_window_list_to_space; do
    if ! grep -q "$upstream_window_helper" "$repository_root/src/space_manager.c"; then
        echo "shared upstream window-transfer helper removed: $upstream_window_helper" >&2
        exit 1
    fi
done
if ! grep -q 'SLSPerformAsynchronousBridgedWindowManagementOperation' "$repository_root/src/space_manager.c"; then
    echo "upstream bridged window transfers were removed with topology fallback" >&2
    exit 1
fi
if ! grep -q 'space_gesture_macos27_switch' "$repository_root/src/space_manager.c"; then
    echo "ordinary macOS 27 space-focus compatibility was removed" >&2
    exit 1
fi
