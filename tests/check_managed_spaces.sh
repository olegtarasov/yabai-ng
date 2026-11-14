#!/bin/bash
# Live primary topology checks using three owned, empty spaces only.
set -euo pipefail
cd "$(dirname "$0")/.."
yabai=${YABAI_BIN:-/opt/homebrew/bin/yabai}
original=$("$yabai" -m query --managed-spaces)
jq -e '.enabled and ."scripting-addition-ready"' <<< "$original" >/dev/null || {
    echo 'Requires enabled managed spaces and a matching scripting addition.' >&2; exit 1;
}
original_uuids=$(jq -c '[.spaces[].uuid]' <<< "$original")
owned='[]'
index_for_uuid() { "$yabai" -m query --spaces | jq -r --arg uuid "$1" '.[] | select(.uuid == $uuid) | .index'; }
cleanup() {
    local result=$? uuid index
    trap - EXIT
    while read -r uuid; do
        [[ -n "$uuid" ]] || continue
        index=$(index_for_uuid "$uuid")
        [[ -z "$index" ]] || "$yabai" -m space "$index" --destroy >/dev/null 2>&1 || true
    done < <(jq -r '.[]' <<< "$owned")
    exit "$result"
}
trap cleanup EXIT
for count in 1 2 3; do
    "$yabai" -m space --create
    settled=false
    for ((attempt=0; attempt<100; attempt++)); do
        state=$("$yabai" -m query --managed-spaces)
        owned=$(jq -c --argjson original "$original_uuids" '[.spaces[].uuid | select(. as $uuid | $original | index($uuid) | not)]' <<< "$state")
        if [[ $(jq length <<< "$owned") == "$count" ]]; then settled=true; break; fi
        sleep 0.1
    done
    $settled || { echo 'FAIL creation admission' >&2; exit 1; }
done
read -r first second third < <(jq -r 'join(" ")' <<< "$owned")
# Swap the endpoints, then move the last fixture to the first fixture's position.
"$yabai" -m space "$(index_for_uuid "$first")" --swap "$(index_for_uuid "$third")"
expected=$(jq -cn --arg a "$third" --arg b "$second" --arg c "$first" '[$a,$b,$c]')
assert_order() {
    local expected=$1 state actual physical
    for ((attempt=0; attempt<100; attempt++)); do
        state=$("$yabai" -m query --managed-spaces)
        actual=$(jq -c --argjson owned "$owned" '[.spaces[].uuid | select(. as $uuid | $owned | index($uuid))]' <<< "$state")
        physical=$("$yabai" -m query --spaces | jq -c --argjson owned "$owned" '[.[] | select(.uuid as $uuid | $owned | index($uuid)) | .uuid]')
        [[ "$actual" != "$expected" || "$physical" != "$expected" ]] || return 0
        sleep 0.1
    done
    echo "FAIL desired/observed order: expected=$expected desired=$actual observed=$physical" >&2; exit 1
}
assert_order "$expected"
echo 'PASS explicit swap commits desired order'
"$yabai" -m space "$(index_for_uuid "$first")" --move "$(index_for_uuid "$third")"
expected=$(jq -cn --arg a "$first" --arg b "$third" --arg c "$second" '[$a,$b,$c]')
assert_order "$expected"
echo 'PASS explicit move commits desired order'
"$yabai" -m space "$(index_for_uuid "$third")" --destroy
owned=$(jq -c --arg uuid "$third" 'map(select(. != $uuid))' <<< "$owned")
expected=$(jq -cn --arg a "$first" --arg b "$second" '[$a,$b]')
assert_order "$expected"
echo 'PASS deletion preserves surviving relative order'
# Repeated reads and readiness refresh must not change desired policy.
before=$("$yabai" -m query --managed-spaces | jq -c '{spaces,windows,"secondary-workspaces":.["secondary-workspaces"]}')
"$yabai" -m query --managed-spaces >/dev/null
"$yabai" -m config managed_spaces on
after=$("$yabai" -m query --managed-spaces | jq -c '{spaces,windows,"secondary-workspaces":.["secondary-workspaces"]}')
[[ "$before" == "$after" ]] || { echo 'FAIL query/readiness refresh changed intent' >&2; exit 1; }
echo 'PASS diagnostic reads and readiness refresh preserve registry'
# Destroy fixtures explicitly and prove the original UUID sequence remains.
for uuid in "$first" "$second"; do
    "$yabai" -m space "$(index_for_uuid "$uuid")" --destroy
    owned=$(jq -c --arg uuid "$uuid" 'map(select(. != $uuid))' <<< "$owned")
done
restored=$("$yabai" -m query --managed-spaces | jq -c '[.spaces[].uuid]')
[[ "$restored" == "$original_uuids" ]] || { echo 'FAIL original managed UUID sequence changed' >&2; exit 1; }
echo 'Live managed-space checks passed; original registry restored.'
