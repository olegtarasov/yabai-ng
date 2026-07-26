#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
baseline_file=$(mktemp "${TMPDIR:-/tmp}/yabai-legacy-baseline.XXXXXX")
current_file=$(mktemp "${TMPDIR:-/tmp}/yabai-legacy-current.XXXXXX")
trap 'rm -f "$baseline_file" "$current_file"' EXIT HUP INT TERM

extract_contract()
{
    awk '
        function target(line) {
            return line ~ /^enum space_op_error space_manager_swap_space_with_space\(/ ||
                   line ~ /^enum space_op_error space_manager_move_space_to_space\(/ ||
                   line ~ /^enum space_op_error space_manager_move_space_to_display\(/ ||
                   line ~ /^enum space_op_error space_manager_destroy_space\(/ ||
                   line ~ /^enum space_op_error space_manager_add_space\(/
        }

        target($0) {
            capture = 1
            started = 0
            depth = 0
        }

        capture {
            print
            opens = gsub(/{/, "{")
            closes = gsub(/}/, "}")
            if (opens > 0) started = 1
            depth += opens - closes
            if (started && depth == 0) {
                print ""
                capture = 0
            }
        }
    '
}

if ! git -C "$repository_root" cat-file -e 7b67591^{commit} 2>/dev/null; then
    echo "legacy provider baseline commit 7b67591 is unavailable" >&2
    exit 1
fi

git -C "$repository_root" show 7b67591:src/space_manager.c |
    extract_contract > "$baseline_file"
extract_contract < "$repository_root/src/space_manager.c" > "$current_file"

if ! cmp -s "$baseline_file" "$current_file"; then
    echo "legacy scripting-addition topology functions differ from 7b67591" >&2
    diff -u "$baseline_file" "$current_file" >&2 || true
    exit 1
fi

if grep -Eq 'managed_space|MANAGED_SPACE' "$repository_root/src/space_manager.c"; then
    echo "space_manager.c crosses the managed-space provider boundary" >&2
    exit 1
fi

if grep -Eq 'SPACE_OP_ERROR_(QUEUED|LIMIT_REACHED|ACCESSIBILITY|TOPOLOGY_BACKEND)' \
    "$repository_root/src/space_manager.h"; then
    echo "provider-only errors leaked into space_manager.h" >&2
    exit 1
fi

if grep -Eq 'managed_space_sip_safe|managed_space_topology|CoreDock|AXUIElement|CGEventTap|watchdog|queue' \
    "$repository_root/src/managed_space_legacy.c" \
    "$repository_root/src/managed_space_legacy.h"; then
    echo "legacy adapter contains SIP-safe policy or resources" >&2
    exit 1
fi

if grep -Eq 'SCRIPTING_ADDITION|scripting_addition_' \
    "$repository_root/src/managed_space_sip_safe.m" \
    "$repository_root/src/managed_space_sip_safe.h"; then
    echo "SIP-safe implementation knows about the scripting-addition provider" >&2
    exit 1
fi

legacy_call_count=$(
    grep -Ec 'return space_manager_(add_space|destroy_space|move_space_to_space|swap_space_with_space|move_space_to_display)' \
        "$repository_root/src/managed_space_legacy.c"
)
if [ "$legacy_call_count" -ne 5 ]; then
    echo "legacy adapter is no longer a transparent five-operation adapter" >&2
    exit 1
fi

grep -RIl 'managed_space_sip_safe_' "$repository_root/src" |
    sed "s|$repository_root/||" |
    while IFS= read -r safe_reference_file; do
        case "$safe_reference_file" in
            src/event_signal.c | \
            src/managed_space.c | \
            src/managed_space.h | \
            src/managed_space_sip_safe.h | \
            src/managed_space_sip_safe.m | \
            src/managed_space_topology.m)
                ;;
            *)
                echo "SIP-safe implementation crossed into $safe_reference_file" >&2
                exit 1
                ;;
        esac
    done

if grep -Eq 'kCGEvent(KeyDown|FlagsChanged)' "$repository_root/src/mouse_handler.h"; then
    echo "SIP-safe keyboard monitoring leaked into the permanent mouse event mask" >&2
    exit 1
fi
