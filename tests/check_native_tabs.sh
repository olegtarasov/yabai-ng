#!/bin/bash
# Opt-in live regression suite. Run from an empty BSP space with managed mode on.
set -euo pipefail
cd "$(dirname "$0")/.."
yabai=${YABAI_BIN:-/opt/homebrew/bin/yabai}
space=$($yabai -m query --spaces --space)
jq -e '.type == "bsp" and ."is-managed" and (.windows | length == 0)' <<< "$space" >/dev/null || {
    echo 'Run this live test on an empty managed BSP space.' >&2; exit 1;
}
space_index=$(jq -r '.index' <<< "$space")
app="$PWD/tests/bin/YabaiNativeTabTest.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.yabai.native-tab-test</string>
<key>CFBundleName</key><string>YabaiNativeTabTest</string>
<key>CFBundleExecutable</key><string>YabaiNativeTabTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
clang tests/integration/native_tabs.m -framework Cocoa -o "$app/Contents/MacOS/YabaiNativeTabTest"
control="$PWD/tests/bin/native-tab-control"
state="$PWD/tests/bin/native-tab-state"
rm -f "$control"
mkfifo "$control"
$yabai -m rule --add label=native-tab-fixture app='^YabaiNativeTabTest$' manage=tab
"$app/Contents/MacOS/YabaiNativeTabTest" < "$control" > "$state" 2> "$state.err" &
fixture_pid=$!
cleanup() {
    kill "$fixture_pid" 2>/dev/null || true
    exec 3>&-
    rm -f "$control"
    $yabai -m rule --remove native-tab-fixture || true
    $yabai -m space --focus "$space_index" || true
}
trap cleanup EXIT
exec 3> "$control"

send() {
    local expected=$(( $(wc -l < "$state") + 1 ))
    printf '%s\n' "$1" >&3
    for ((attempt=0; attempt<100; attempt++)); do
        [[ $(wc -l < "$state") -ge $expected ]] && return
        sleep 0.1
    done
    echo "Fixture did not acknowledge $1" >&2; exit 1
}
ids() { read -r _ first second third independent < <(tail -1 "$state"); }
await_window() {
    local id=$1 predicate=$2 label=$3
    for ((attempt=0; attempt<100; attempt++)); do
        if $yabai -m query --windows --window "$id" 2>/dev/null | jq -e "$predicate" >/dev/null; then
            echo "PASS $label"; return
        fi
        sleep 0.1
    done
    echo "FAIL $label" >&2
    $yabai -m query --windows --window "$id" >&2 || true; exit 1
}
await_count() {
    local count=$1 label=$2
    for ((attempt=0; attempt<100; attempt++)); do
        if $yabai -m query --spaces --space "$space_index" | jq -e ".\"displayable-window-count\" == $count and (.\"displayable-windows\" | length) == $count" >/dev/null; then
            echo "PASS $label"; return
        fi
        sleep 0.1
    done
    echo "FAIL $label" >&2
    $yabai -m query --spaces --space "$space_index" >&2; exit 1
}
for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "$state" ]] && break
    sleep 0.1
done
ids
await_window "$first" '."is-visible" and (."is-floating" | not)' 'first admitted'
full_width=$($yabai -m query --windows --window "$first" | jq '.frame.w')
full=".frame.w == $full_width"
managed='(."is-tab" | not) and (."is-floating" | not)'
for ((cycle=1; cycle<=3; cycle++)); do
    send add-second; ids
    await_window "$second" "$managed and $full" "selected tab inherits tile ($cycle)"
    await_count 1 'tab group counted once'
    send add-third; ids
    await_window "$third" "$managed and $full" 'third tab inherits tile'
    send first
    await_window "$first" "$managed and $full" 'switch back preserves tile'
    send second
    await_window "$second" "$managed and $full" 'switch forward preserves tile'
    $yabai -m window "$second" --toggle float
    await_window "$second" '."is-floating"' 'selected tab floats'
    send third
    await_window "$third" '."is-floating" and (."is-tab" | not)' 'float follows tab selection'
    $yabai -m window "$third" --toggle float
    await_window "$third" "$managed and $full" 'selected tab unfloat tiles'
    send independent; ids
    await_window "$independent" "$managed and .frame.w < $full_width * 0.75" 'independent same-app window remains independent'
    await_count 2 'independent window counted separately'
    send close-independent
    await_window "$third" "$managed and $full" 'closing independent restores full tile'
    send first
    await_window "$first" "$managed and $full" 'select original before destruction'
    send close-first; ids
    send second
    await_window "$second" "$managed and $full" 'survivor promoted after parent closes'
    send third
    await_window "$third" "$managed and $full" 'all survivors reparented'
    send displace
    await_window "$third" "$managed and $full" 'managed selected tab corrects app move and resize'
    send detach-second
    await_window "$second" "$managed and .frame.w < $full_width * 0.75" 'detached tab tiles independently'
    await_count 2 'detached tab counted separately'
    send recreate; ids
    await_window "$first" "$managed and $full" 'workspace recreation restores tile'
    await_count 1 'workspace recreation restores presentation'
done
background_index=$($yabai -m query --spaces | jq -r --argjson current "$space_index" '[.[] | select(.index != $current and .type == "bsp" and (.windows | length == 0))][0].index // empty')
if [[ -n "$background_index" ]]; then
    $yabai -m space --focus "$background_index"
    await_count 1 'unfocused native tab group keeps space occupied'
    $yabai -m space --focus "$space_index"
fi
send hide
await_count 0 'hidden group not counted'
send show
await_count 1 'unhidden group counted'
# Reapplying ordinary management must remove old tab relationships.
send add-second; ids
await_window "$second" "$managed and $full" 'group before rule removal'
$yabai -m rule --add label=native-tab-fixture app='^YabaiNativeTabTest$' manage=on
$yabai -m rule --apply native-tab-fixture
await_window "$first" '(."is-tab" | not)' 'rule removal clears inactive tab classification'
await_window "$second" '(."is-tab" | not)' 'rule removal clears selected tab classification'
echo 'Live native tab checks passed.'
