#!/bin/bash
# Opt-in real WindowServer/AX checks. No synthetic mouse or keyboard input.
set -euo pipefail
cd "$(dirname "$0")/.."
yabai=${YABAI_BIN:-/opt/homebrew/bin/yabai}
manual=false
manual_timeout=${MANUAL_TIMEOUT_SECONDS:-120}
[[ "$manual_timeout" =~ ^[1-9][0-9]*$ ]] || { echo "MANUAL_TIMEOUT_SECONDS must be a positive integer." >&2; exit 1; }
if [[ ${1:-} == --manual ]]; then manual=true; shift; fi
if [[ $# != 0 ]]; then
    echo "Usage: SOURCE_SPACE=<index> TARGET_DISPLAY=<index> YABAI_BIN=<path> $0 [--manual]" >&2
    exit 1
fi

original_space=$("$yabai" -m query --spaces --space | jq -r '.index')
original_window=$("$yabai" -m query --windows | jq -r '[.[] | select(."has-focus")][0].id // 0')
source=$("$yabai" -m query --spaces --space "${SOURCE_SPACE:-$original_space}")
jq -e '.type == "bsp" and ."is-managed" and (.windows | length == 0)' <<< "$source" >/dev/null || {
    echo 'Select an empty managed BSP source using SOURCE_SPACE, or run from one.' >&2; exit 1;
}
source_index=$(jq -r '.index' <<< "$source")
source_display=$(jq -r '.display' <<< "$source")
source_uuid=$(jq -r '.uuid' <<< "$source")
spaces=$("$yabai" -m query --spaces)
target=$(jq -c --argjson source "$source_display" --arg requested "${TARGET_DISPLAY:-}" '
    [.[] | select(.display != $source and ($requested == "" or (.display | tostring) == $requested))]
    | group_by(.display)
    | map(select(([.[] | select(."is-native-fullscreen" | not)] | length) == 1))
    | flatten
    | map(select(.type == "bsp" and (."is-managed" | not) and ."is-visible" and (.windows | length == 0)))
    | .[0] // empty' <<< "$spaces")
[[ -n "$target" ]] || {
    echo 'Need another display with exactly one normal space: visible, empty, unmanaged BSP.' >&2; exit 1;
}
target_index=$(jq -r '.index' <<< "$target")
target_display=$(jq -r '.display' <<< "$target")
target_uuid=$(jq -r '.uuid' <<< "$target")
before=$("$yabai" -m query --managed-spaces)
jq -e '.enabled and ."topology-state" == "idle" and ."topology-queue-depth" == 0 and (."topology-owns-mission-control" | not)' <<< "$before" >/dev/null || {
    echo 'Managed mode must be enabled with an idle provider before this test.' >&2; exit 1;
}
registry=$(jq -c '.spaces | map(del(."window-count"))' <<< "$before")
provider=$(jq -r '."topology-resolved-provider"' <<< "$before")
if "$yabai" -m query --windows | jq -e 'any(.app == "YabaiMultiDisplayTest")' >/dev/null; then
    echo 'A previous YabaiMultiDisplayTest instance is still running.' >&2; exit 1
fi

mkdir -p tests/bin
run_dir=$(mktemp -d "$PWD/tests/bin/multi-display.XXXXXX")
app="$run_dir/YabaiMultiDisplayTest.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yabai.multi-display-test</string>
<key>CFBundleName</key><string>YabaiMultiDisplayTest</string>
<key>CFBundleExecutable</key><string>YabaiMultiDisplayTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
clang tests/integration/multi_display_drag.m -framework Cocoa -o "$app/Contents/MacOS/YabaiMultiDisplayTest"
control="$run_dir/control"
state="$run_dir/state"
mkfifo "$control"
rule_label="multi-display-fixture-$$"
fixture_pid=
rule_installed=false
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
    exec 3>&- || true
    if $rule_installed; then "$yabai" -m rule --remove "$rule_label" >/dev/null 2>&1 || true; fi
    if [[ "$original_window" != 0 ]]; then
        "$yabai" -m window --focus "$original_window" >/dev/null 2>&1 || "$yabai" -m space --focus "$original_space" >/dev/null 2>&1 || true
    else
        "$yabai" -m space --focus "$original_space" >/dev/null 2>&1 || true
    fi
    # Keep bounded diagnostics on failure. All files and windows belong to this test.
    if (( result == 0 )); then
        find "$run_dir" -depth -type f -delete
        find "$run_dir" -depth -type p -delete
        find "$run_dir" -depth -type d -exec rmdir {} \;
    else
        echo "Fixture diagnostics: $run_dir" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$yabai" -m rule --add label="$rule_label" app='^YabaiMultiDisplayTest$' manage=tab
rule_installed=true
"$yabai" -m space --focus "$source_index"
"$app/Contents/MacOS/YabaiMultiDisplayTest" < "$control" > "$state" 2> "$state.err" &
fixture_pid=$!
exec 3> "$control"

fail() { echo "FAIL $1" >&2; exit 1; }
send() {
    local expected attempt
    expected=$(( $(wc -l < "$state") + 1 ))
    printf '%s\n' "$1" >&3
    for ((attempt=0; attempt<100; attempt++)); do
        [[ $(wc -l < "$state") -ge $expected ]] && return
        kill -0 "$fixture_pid" 2>/dev/null || fail 'fixture exited before acknowledging command'
        sleep 0.1
    done
    fail "fixture did not acknowledge $1"
}
fixture_id() { tail -1 "$state" | jq -r ".${1}"; }
window_matches() { "$yabai" -m query --windows --window "$1" 2>/dev/null | jq -e "$2" >/dev/null; }
await_window() {
    local wid=$1 predicate=$2 label=$3 attempt
    for ((attempt=0; attempt<100; attempt++)); do
        if window_matches "$wid" "$predicate"; then echo "PASS $label"; return; fi
        sleep 0.1
    done
    "$yabai" -m query --windows --window "$wid" >&2 || true
    fail "$label"
}
hold_window() {
    local wid=$1 predicate=$2 label=$3 attempt
    for ((attempt=0; attempt<20; attempt++)); do
        window_matches "$wid" "$predicate" || fail "$label"
        sleep 0.1
    done
    echo "PASS $label"
}
await_residence() {
    local wid=$1 secondary=$2 label=$3 attempt
    for ((attempt=0; attempt<100; attempt++)); do
        if "$yabai" -m query --managed-spaces | jq -e --argjson wid "$wid" --arg home "$source_uuid" --arg secondary "$secondary" '
            any(.windows[]; .id == $wid and ."managed-space-uuid" == $home and ."secondary-space-uuid" == $secondary)' >/dev/null; then
            echo "PASS $label"; return
        fi
        sleep 0.1
    done
    fail "$label"
}
await_absent() {
    local wid=$1 attempt
    for ((attempt=0; attempt<100; attempt++)); do
        if ! "$yabai" -m query --windows --window "$wid" >/dev/null 2>&1; then return; fi
        sleep 0.1
    done
    fail "closed fixture window $wid remained tracked"
}
manual_drop() {
    local wid=$1 destination=$2 label=$3 attempt active=false snapshot
    echo "ACTION $label: drag fixture window $wid by its title bar to space $destination."
    echo 'Hold the pointer long enough to inspect the red preview, then release. No input is synthesized.'
    for ((attempt=0; attempt<manual_timeout*20; attempt++)); do
        snapshot=$("$yabai" -m query --managed-spaces)
        if jq -e '."dragged-window-count" > 0' <<< "$snapshot" >/dev/null; then active=true; fi
        if $active && jq -e '."dragged-window-count" == 0' <<< "$snapshot" >/dev/null &&
            window_matches "$wid" ".space == $destination"; then
            echo "PASS $label (drag observed, released into destination)"; return
        fi
        sleep 0.05
    done
    fail "$label: no completed drag observed; use physical input if app-directed automation bypasses the event tap"
}

for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "$state" ]] && break
    sleep 0.1
done
[[ -s "$state" ]] || fail 'fixture did not start'
primary=$(fixture_id primary)
anchor=$(fixture_id anchor)
source_predicate=".space == $source_index and .display == $source_display and (.\"is-floating\" | not)"
target_predicate=".space == $target_index and .display == $target_display and (.\"is-floating\" | not)"
await_window "$primary" "$source_predicate" 'primary tiles on managed source'
await_window "$anchor" "$source_predicate" 'independent anchor tiles on source'

"$yabai" -m window "$primary" --display "$target_display"
await_window "$primary" "$target_predicate" 'window --display reaches secondary workspace'
await_residence "$primary" "$target_uuid" 'secondary residence retains managed recovery home'
for ((cycle=1; cycle<=3; cycle++)); do
    send auxiliary
    auxiliary=$(fixture_id auxiliary)
    await_window "$auxiliary" '."is-visible" and (."is-floating" | not)' "reconciliation trigger admitted ($cycle)"
    send close-auxiliary
    await_absent "$auxiliary"
    hold_window "$primary" "$target_predicate" "occupied secondary survives reconciliation ($cycle)"
done
"$yabai" -m window "$primary" --space "$source_index"
await_window "$primary" "$source_predicate" 'window --space returns to managed home'
await_residence "$primary" '' 'return clears secondary residence'
"$yabai" -m window "$primary" --space "$target_index"
await_window "$primary" "$target_predicate" 'window --space reaches secondary workspace'
"$yabai" -m window "$primary" --display "$source_display"
await_window "$primary" "$source_predicate" 'window --display returns to source display'
await_residence "$primary" '' 'display return clears secondary residence'

if $manual; then
    "$yabai" -m window --focus "$primary"
    manual_drop "$primary" "$target_index" 'source to empty secondary preview/drop'
    await_residence "$primary" "$target_uuid" 'physical drop commits secondary residence'
    manual_drop "$primary" "$source_index" 'secondary to populated source preview/drop'
    await_residence "$primary" '' 'physical return commits managed home'
    # A center swap can move the anchor; reset only our fixture windows.
    "$yabai" -m window "$anchor" --space "$source_index"
    await_window "$anchor" "$source_predicate" 'anchor restored after manual drop'
else
    echo 'NOT EXERCISED physical title-bar dragging and visual preview (rerun with --manual).'
fi

send primary
send add-tab
tab=$(fixture_id tab)
await_window "$tab" "$source_predicate and (.\"is-tab\" | not)" 'native tab inherits source tile'
"$yabai" -m window "$tab" --display "$target_display"
await_window "$tab" "$target_predicate and (.\"is-tab\" | not)" 'selected native tab moves to secondary'
send primary
await_window "$primary" "$target_predicate and (.\"is-tab\" | not)" 'switching tabs preserves secondary placement'
send tab
await_window "$tab" "$target_predicate and (.\"is-tab\" | not)" 'switching forward preserves secondary placement'
"$yabai" -m window "$tab" --space "$source_index"
await_window "$tab" "$source_predicate and (.\"is-tab\" | not)" 'native group returns to source'
send primary
await_window "$primary" "$source_predicate and (.\"is-tab\" | not)" 'original native tab returns with group'
send detach-tab
await_window "$tab" "$source_predicate and (.\"is-tab\" | not)" 'detached tab tiles independently'
"$yabai" -m window "$tab" --space "$target_index"
await_window "$tab" "$target_predicate" 'detached tab moves independently'
hold_window "$primary" "$source_predicate" 'detached movement leaves original tab on source'

after=$("$yabai" -m query --managed-spaces)
[[ $(jq -c '.spaces | map(del(."window-count"))' <<< "$after") == "$registry" ]] || fail 'managed registry changed'
jq -e --arg provider "$provider" '."topology-resolved-provider" == $provider and ."topology-state" == "idle" and ."topology-queue-depth" == 0 and (."topology-owns-mission-control" | not) and ."dragged-window-count" == 0 and ."pending-window-repair-count" == 0' <<< "$after" >/dev/null || fail 'provider or drag state did not return idle'
"$yabai" -m query --spaces | jq -e --arg uuid "$target_uuid" --argjson display "$target_display" 'any(.[]; .uuid == $uuid and .display == $display and (."is-managed" | not))' >/dev/null || fail 'secondary workspace identity changed'
echo 'Live multi-display placement checks passed; managed registry/provider preserved.'
