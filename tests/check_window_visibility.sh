#!/bin/bash
# Opt-in live integration check. Run on an empty BSP space with a running yabai.
# The fixture owns every window it opens and is terminated on exit.
set -euo pipefail
cd "$(dirname "$0")/.."
yabai=${YABAI_BIN:-/opt/homebrew/bin/yabai}
space=$($yabai -m query --spaces --space)
if ! jq -e '.type == "bsp" and (.windows | length == 0)' <<< "$space" >/dev/null; then
    echo 'Run this live test on an empty BSP space.' >&2
    exit 1
fi
app="$PWD/tests/bin/YabaiVisibilityTest.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yabai.visibility-test</string>
<key>CFBundleName</key><string>YabaiVisibilityTest</string>
<key>CFBundleExecutable</key><string>YabaiVisibilityTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
clang tests/integration/window_visibility.m -framework Cocoa -o "$app/Contents/MacOS/YabaiVisibilityTest"
control="$PWD/tests/bin/visibility-control"
state="$PWD/tests/bin/visibility-state"
rm -f "$control"
mkfifo "$control"
"$app/Contents/MacOS/YabaiVisibilityTest" < "$control" > "$state" 2> "$state.err" &
fixture_pid=$!
cleanup() { kill "$fixture_pid" 2>/dev/null || true; exec 3>&-; rm -f "$control"; }
trap cleanup EXIT
exec 3> "$control"

send() {
    local expected
    expected=$(( $(wc -l < "$state") + $(printf '%s\n' "$1" | wc -l) ))
    printf '%s\n' "$1" >&3
    for ((attempt=0; attempt<60; attempt++)); do
        [[ $(wc -l < "$state") -ge $expected ]] && return
        sleep 0.1
    done
    echo 'Fixture did not acknowledge command.' >&2
    exit 1
}

await_frame() {
    local id=$1 predicate=$2 label=$3
    for ((attempt=0; attempt<60; attempt++)); do
        if $yabai -m query --windows --window "$id" 2>/dev/null | jq -e "$predicate" >/dev/null; then
            echo "PASS $label"
            return
        fi
        sleep 0.1
    done
    echo "FAIL $label" >&2
    $yabai -m query --windows --window "$id" >&2 || true
    exit 1
}
for ((attempt=0; attempt<60; attempt++)); do
    primary=$(awk '$1 == "primary" { print $2; exit }' "$state")
    [[ -n "$primary" ]] && break
    sleep 0.1
done
[[ -n "$primary" ]]
await_frame "$primary" '."split-type" == "none" and ."is-visible"' 'primary admitted'
full_width=$($yabai -m query --windows --window "$primary" | jq '.frame.w')
half=".frame.w < $full_width * 0.75"
full=".frame.w == $full_width"
send new
await_frame "$primary" "$half" 'new window tiles'
secondary=$(awk '$1 == "secondary" && $2 != 0 { id=$2 } END {print id}' "$state")
[[ -n "$secondary" ]]
for ((cycle=1; cycle<=5; cycle++)); do
    send out
    await_frame "$primary" "$full" "retained order-out reclaims space ($cycle)"
    await_frame "$secondary" '."split-type" == "none" and (."is-visible" | not)' 'retained window stays tracked without a tile'
    send in
    await_frame "$primary" "$half" "retained order-in tiles ($cycle)"
    await_frame "$secondary" '."split-type" != "none" and ."is-visible"' 'retained ID is managed again'
done
send background-out
await_frame "$secondary" "$full" 'background order-out reclaims space'
send background-in
await_frame "$secondary" "$half" 'background order-in restores tiling'
send $'out\nin\nout\nin'
await_frame "$primary" "$half" 'queued visibility transitions converge'
$yabai -m window "$secondary" --toggle float
await_frame "$primary" "$full" 'manual float reclaims space'
send $'out\nin'
await_frame "$secondary" '."is-floating" and ."split-type" == "none" and ."is-visible"' 'visibility preserves manual floating'
await_frame "$primary" "$full" 'floating reopen preserves full tile'
$yabai -m window "$secondary" --toggle float
await_frame "$primary" "$half" 'manual unfloat restores tiling'
send minimize
await_frame "$primary" "$full" 'minimize reclaims space'
send restore
await_frame "$primary" "$half" 'deminimize restores tiling'
send hide
await_frame "$primary" '."is-hidden"' 'application hide'
send show
await_frame "$primary" "$half and (.\"is-hidden\" | not)" 'application unhide restores tiling'
send destroy
await_frame "$primary" "$full" 'destroy reclaims space'
send new
await_frame "$primary" "$half" 'new window after destroy tiles'
send destroy
await_frame "$primary" "$full" 'second destroy reclaims space'
echo 'Live window visibility checks passed.'
