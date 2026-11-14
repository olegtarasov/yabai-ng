#!/bin/bash
# Opt-in real native fullscreen/focus check. No synthetic input or focus repair.
set -euo pipefail
cd "$(dirname "$0")/.."
yabai=${YABAI_BIN:-/opt/homebrew/bin/yabai}
original_space=$("$yabai" -m query --spaces --space | jq -r '.index')
original_window=$("$yabai" -m query --windows | jq -r '[.[] | select(."has-focus")][0].id // 0')
source=$("$yabai" -m query --spaces --space "${SOURCE_SPACE:-$original_space}")
jq -e '.type == "bsp" and ."is-managed" and (.windows | length == 0)' <<< "$source" >/dev/null || {
    echo 'Run on an empty managed BSP space, or select one with SOURCE_SPACE.' >&2; exit 1;
}
source_index=$(jq -r '.index' <<< "$source")
source_uuid=$(jq -r '.uuid' <<< "$source")
before=$("$yabai" -m query --managed-spaces)
jq -e '.enabled and ."scripting-addition-ready" and ."pending-window-repair-count" == 0' <<< "$before" >/dev/null || {
    echo 'Managed mode must be ready with no pending window repairs.' >&2; exit 1;
}
registry=$(jq -c '.spaces | map(del(."window-count", .index))' <<< "$before")
repair_attempts=$(jq -r '."window-repair-attempt-count"' <<< "$before")
[[ "$repair_attempts" =~ ^[0-9]+$ ]] || { echo 'The running binary must expose the repair-attempt counter.' >&2; exit 1; }
if "$yabai" -m query --windows | jq -e 'any(.app == "YabaiFullscreenTest")' >/dev/null; then
    echo 'A previous YabaiFullscreenTest instance is still running.' >&2; exit 1
fi

mkdir -p tests/bin
run_dir=$(mktemp -d "$PWD/tests/bin/fullscreen.XXXXXX")
app="$run_dir/YabaiFullscreenTest.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yabai.fullscreen-test</string>
<key>CFBundleName</key><string>YabaiFullscreenTest</string>
<key>CFBundleExecutable</key><string>YabaiFullscreenTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
clang tests/integration/fullscreen.m -framework Cocoa -o "$app/Contents/MacOS/YabaiFullscreenTest"
control="$run_dir/control"
state="$run_dir/state"
mkfifo "$control"
rule_label="fullscreen-fixture-$$"
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
"$yabai" -m rule --add label="$rule_label" app='^YabaiFullscreenTest$' manage=off
rule_installed=true
if [[ "$original_space" != "$source_index" ]]; then "$yabai" -m space --focus "$source_index"; fi
source_focused=false
for ((attempt=0; attempt<100; attempt++)); do
    current_uuid=$("$yabai" -m query --spaces --space | jq -r '.uuid')
    if [[ "$current_uuid" == "$source_uuid" ]]; then source_focused=true; break; fi
    sleep 0.1
done
$source_focused || { echo 'FAIL fixture source did not become active' >&2; exit 1; }
"$app/Contents/MacOS/YabaiFullscreenTest" < "$control" > "$state" 2> "$state.err" &
fixture_pid=$!
exec 3> "$control"

fail() { echo "FAIL $1" >&2; exit 1; }
send() {
    local command=$1 expected=$(( $(wc -l < "$state") + 1 )) attempt
    printf '%s\n' "$command" >&3
    for ((attempt=0; attempt<150; attempt++)); do
        if [[ $(wc -l < "$state") -ge $expected ]]; then
            if [[ "$command" == enter || "$command" == exit ]]; then
                [[ $(awk 'END {print $2}' "$state") == "$command" ]] || fail "fixture fullscreen transition: $(tail -1 "$state")"
            fi
            return
        fi
        sleep 0.1
    done
    fail "fixture did not acknowledge $command"
}
for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "$state" ]] && break
    sleep 0.1
done
[[ -s "$state" ]] || fail 'fixture launch'
wid=$(awk 'NR == 1 {print $3}' "$state")
[[ "$wid" =~ ^[1-9][0-9]*$ ]] || fail 'fixture window identity'
for ((attempt=0; attempt<100; attempt++)); do
    snapshot=$("$yabai" -m query --managed-spaces)
    home=$(jq -r --argjson id "$wid" '.windows[] | select(.id == $id) | ."managed-space-uuid"' <<< "$snapshot")
    [[ "$home" == "$source_uuid" ]] && break
    sleep 0.1
done
[[ "$home" == "$source_uuid" ]] || fail 'unmanaged window namespace admission'

assert_state() {
    local fullscreen=$1 snapshot current focused window
    snapshot=$("$yabai" -m query --managed-spaces)
    [[ $(jq -c '.spaces | map(del(."window-count", .index))' <<< "$snapshot") == "$registry" ]] || fail 'desired registry changed'
    jq -e --argjson id "$wid" --arg home "$home" --argjson attempts "$repair_attempts" '
        ."pending-window-repair-count" == 0 and ."window-repair-attempt-count" == $attempts
        and any(.windows[]; .id == $id and ."managed-space-uuid" == $home)' <<< "$snapshot" >/dev/null || fail 'namespace repair churn or changed home'
    current=$("$yabai" -m query --spaces --space)
    jq -e --argjson id "$wid" --argjson fullscreen "$fullscreen" --arg uuid "$source_uuid" '
        ."is-native-fullscreen" == $fullscreen and (.windows | index($id)) != null
        and (if $fullscreen then (."is-managed" | not) else .uuid == $uuid end)' <<< "$current" >/dev/null || fail 'actual fullscreen Space membership'
    # With no explicit ID, this asks the frontmost application's focused AX
    # window. A cached has-focus bit alone would conceal a stolen focus.
    focused=$("$yabai" -m query --windows --window 2>/dev/null) || fail 'frontmost application has no focused window'
    jq -e --argjson id "$wid" '.id == $id and ."has-focus"' <<< "$focused" >/dev/null || fail 'native fullscreen lost focus'
    window=$("$yabai" -m query --windows --window "$wid")
    jq -e --argjson fullscreen "$fullscreen" '."is-floating" and ."is-native-fullscreen" == $fullscreen' <<< "$window" >/dev/null || fail 'cached fullscreen/window state diverged'
}

for ((cycle=1; cycle<=3; cycle++)); do
    send enter
    for ((sample=0; sample<10; sample++)); do assert_state true; sleep 0.1; done
    echo "PASS unmanaged fullscreen retains focus and namespace ($cycle)"
    send exit
    for ((sample=0; sample<10; sample++)); do assert_state false; sleep 0.1; done
    echo "PASS windowed return retains focus and namespace ($cycle)"
done
# A reapplied rule is deliberate placement and must replace the remembered home.
target=$("$yabai" -m query --spaces | jq -c --arg uuid "$source_uuid" '[.[] | select(."is-managed" and (."is-native-fullscreen" | not) and .uuid != $uuid and (.windows | length == 0))][0] // empty')
if [[ -n "$target" ]]; then
    target_index=$(jq -r '.index' <<< "$target")
    target_uuid=$(jq -r '.uuid' <<< "$target")
    "$yabai" -m rule --add label="$rule_label" app='^YabaiFullscreenTest$' manage=off space="$target_index"
    "$yabai" -m rule --apply "$rule_label"
    matched=false
    for ((attempt=0; attempt<100; attempt++)); do
        actual=$("$yabai" -m query --windows --window "$wid" | jq -r '.space')
        snapshot=$("$yabai" -m query --managed-spaces)
        if [[ "$actual" == "$target_index" ]] && jq -e --argjson id "$wid" --arg uuid "$target_uuid" 'any(.windows[]; .id == $id and ."managed-space-uuid" == $uuid)' <<< "$snapshot" >/dev/null; then matched=true; break; fi
        sleep 0.1
    done
    $matched || fail 'reapplied rule did not commit accepted placement'
    "$yabai" -m window "$wid" --space "$source_index"
    echo 'PASS reapplied rule commits placement and explicit return succeeds'
fi
echo 'Live fullscreen checks passed.'
