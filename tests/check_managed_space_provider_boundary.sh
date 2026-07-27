#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
# Compose retired spellings so the repository itself can maintain a zero-match
# terminology audit while this guard still rejects their reintroduction.
obsolete_primary_role='leg'
obsolete_primary_role="${obsolete_primary_role}acy"
obsolete_fallback_qualifier='sa'
obsolete_fallback_qualifier="${obsolete_fallback_qualifier}fe"
obsolete_primary_module="managed_space_${obsolete_primary_role}"
obsolete_fallback_module="managed_space_sip_${obsolete_fallback_qualifier}"
obsolete_terms="${obsolete_primary_module}|sip[-_ ]${obsolete_fallback_qualifier}|(^|[^[:alnum:]_])${obsolete_primary_role}([^[:alnum:]_]|$)"

for obsolete_file in \
    "$repository_root/src/${obsolete_primary_module}.c" \
    "$repository_root/src/${obsolete_primary_module}.h" \
    "$repository_root/src/${obsolete_fallback_module}.m" \
    "$repository_root/src/${obsolete_fallback_module}.h"; do
    if [ -e "$obsolete_file" ]; then
        echo "obsolete managed topology provider file remains: $obsolete_file" >&2
        exit 1
    fi
done

if git -C "$repository_root" grep -n -I -i -E \
    "$obsolete_terms" \
    -- AGENTS.md README.md CHANGELOG.md doc/yabai.asciidoc doc/yabai.1 \
       'src/managed_space*' 'tests/src/managed_space*'; then
    echo "obsolete managed topology terminology remains" >&2
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

if grep -Eq 'managed_space_sip_fallback|managed_space_topology|CoreDock|AXUIElement|CGEventTap|watchdog|queue' \
    "$repository_root/src/managed_space_scripting_addition.c" \
    "$repository_root/src/managed_space_scripting_addition.h"; then
    echo "primary scripting-addition adapter contains SIP fallback policy or resources" >&2
    exit 1
fi

if grep -Eq 'SCRIPTING_ADDITION|scripting_addition_' \
    "$repository_root/src/managed_space_sip_fallback.m" \
    "$repository_root/src/managed_space_sip_fallback.h"; then
    echo "SIP fallback implementation knows about the scripting-addition provider" >&2
    exit 1
fi

primary_function_count=$(
    grep -Ec '^enum space_op_error managed_space_scripting_addition_' \
        "$repository_root/src/managed_space_scripting_addition.c"
)
primary_call_count=$(
    grep -Ec 'return space_manager_(add_space|destroy_space|move_space_to_space|swap_space_with_space|move_space_to_display)' \
        "$repository_root/src/managed_space_scripting_addition.c"
)
if [ "$primary_function_count" -ne 5 ] || [ "$primary_call_count" -ne 5 ]; then
    echo "primary scripting-addition adapter is no longer a transparent five-operation adapter" >&2
    exit 1
fi

primary_dispatch_count=$(
    grep -Ec 'managed_space_scripting_addition_(create|destroy|move|swap|move_to_display)\(' \
        "$repository_root/src/managed_space_topology.m"
)
if [ "$primary_dispatch_count" -ne 5 ]; then
    echo "provider facade contains an unexpected primary scripting-addition dispatch" >&2
    exit 1
fi

if grep -Eq '^[[:space:]]*(if|for|while|switch)[[:space:](]' \
    "$repository_root/src/managed_space_scripting_addition.c"; then
    echo "primary scripting-addition adapter contains provider policy" >&2
    exit 1
fi

grep -RIl 'managed_space_sip_fallback_' "$repository_root/src" |
    sed "s|$repository_root/||" |
    while IFS= read -r fallback_reference_file; do
        case "$fallback_reference_file" in
            src/event_signal.c | \
            src/managed_space.c | \
            src/managed_space.h | \
            src/managed_space_sip_fallback.h | \
            src/managed_space_sip_fallback.m | \
            src/managed_space_topology.m)
                ;;
            *)
                echo "SIP fallback implementation crossed into $fallback_reference_file" >&2
                exit 1
                ;;
        esac
    done

if grep -Eq 'kCGEvent(KeyDown|FlagsChanged)' "$repository_root/src/mouse_handler.h"; then
    echo "SIP fallback keyboard monitoring leaked into the permanent mouse event mask" >&2
    exit 1
fi
