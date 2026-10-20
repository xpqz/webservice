#!/usr/bin/env bash
# End-to-end tests against the running stack, through nginx.
# Usage: test/smoke.sh [test_name ...]   (no names: run every test)
set -uo pipefail

BASE=${BASE:-http://localhost:8080}
RUN=$(date +%s)$RANDOM          # suffix that keeps each run's data apart
FAILS=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# req METHOD PATH [JSON] -> sets STATUS, BODY, HEADERS
req() {
    : > "$TMP/b"; : > "$TMP/h"
    local args=(-s -X "$1" -D "$TMP/h" -o "$TMP/b" -w '%{http_code}')
    [ $# -ge 3 ] && args+=(-H 'Content-Type: application/json' --data-binary "$3")
    STATUS=$(curl "${args[@]}" "$BASE$2")
    BODY=$(cat "$TMP/b"); HEADERS=$(tr -d '\r' < "$TMP/h")
}

# expect_eq NAME ACTUAL EXPECTED
expect_eq() {
    if [ "$2" == "$3" ]; then echo "  ok   $1"
    else echo "  FAIL $1: got [$2] want [$3]"; FAILS=$((FAILS+1)); fi
}

jqb() { jq -r "$1" <<<"$BODY"; }

test_health() {
    req GET /health
    expect_eq "health status" "$STATUS" 200
    expect_eq "health body" "$(jqb .status)" ok
}

test_unknown_route() {
    req GET /nope
    expect_eq "unknown route status" "$STATUS" 404
    expect_eq "unknown route message" "$(jqb .message)" "Not Found"
}

test_openapi() {
    req GET /openapi.json
    expect_eq "openapi status" "$STATUS" 200
    expect_eq "openapi title" "$(jqb .info.title)" Issues
}

test_label_create() {
    req POST /labels "{\"name\":\"bug-$RUN\",\"color\":\"d73a4a\",\"description\":\"Broken ⍳ café\"}"
    expect_eq "label create status" "$STATUS" 201
    expect_eq "label create name" "$(jqb .name)" "bug-$RUN"
    expect_eq "label create color" "$(jqb .color)" d73a4a
    expect_eq "label create description" "$(jqb .description)" "Broken ⍳ café"
    expect_eq "label create id is number" "$(jqb '.id|type')" number
}

test_label_create_defaults() {
    req POST /labels "{\"name\":\"x-$RUN\"}"
    expect_eq "label defaults status" "$STATUS" 201
    expect_eq "label default color" "$(jqb .color)" ededed
    expect_eq "label default description" "$(jqb .description)" null
}

test_label_missing_name() {
    req POST /labels '{}'
    expect_eq "label missing name status" "$STATUS" 422
    expect_eq "label missing name error" "$(jq -cS '.errors[0]' <<<"$BODY")" '{"code":"missing_field","field":"name","resource":"Label"}'
    req POST /labels '{"name":""}'
    expect_eq "label empty name status" "$STATUS" 422
}

test_label_duplicate() {
    req POST /labels "{\"name\":\"dup-$RUN\"}"
    req POST /labels "{\"name\":\"DUP-$RUN\"}"
    expect_eq "label duplicate status" "$STATUS" 422
    expect_eq "label duplicate code" "$(jqb '.errors[0].code')" already_exists
}

test_label_get() {
    req POST /labels "{\"name\":\"get-$RUN\"}"
    req GET "/labels/get-$RUN"
    expect_eq "label get status" "$STATUS" 200
    expect_eq "label get name" "$(jqb .name)" "get-$RUN"
    req GET "/labels/GET-$RUN"
    expect_eq "label get case-insensitive" "$STATUS" 200
    req GET "/labels/nope-$RUN"
    expect_eq "label get unknown status" "$STATUS" 404
    expect_eq "label get unknown message" "$(jqb .message)" "Not Found"
}

test_label_update() {
    req POST /labels "{\"name\":\"old-$RUN\"}"
    req PATCH "/labels/old-$RUN" "{\"new_name\":\"defect-$RUN\",\"color\":\"000000\"}"
    expect_eq "label update status" "$STATUS" 200
    expect_eq "label update name" "$(jqb .name)" "defect-$RUN"
    expect_eq "label update color" "$(jqb .color)" 000000
    req GET "/labels/old-$RUN"
    expect_eq "label old name gone" "$STATUS" 404
    req PATCH "/labels/nope-$RUN" '{"color":"111111"}'
    expect_eq "label update unknown" "$STATUS" 404
}

test_label_delete() {
    req POST /labels "{\"name\":\"del-$RUN\"}"
    req DELETE "/labels/del-$RUN"
    expect_eq "label delete status" "$STATUS" 204
    expect_eq "label delete body" "$BODY" ""
    req GET "/labels/del-$RUN"
    expect_eq "label deleted is gone" "$STATUS" 404
    req DELETE "/labels/del-$RUN"
    expect_eq "label delete unknown" "$STATUS" 404
}

test_label_list() {
    req POST /labels "{\"name\":\"zz-list-$RUN\"}"
    req GET "/labels?per_page=100&page=1"
    expect_eq "label list status" "$STATUS" 200
    expect_eq "label list is array" "$(jqb type)" array
    expect_eq "label list sorted" "$(jq -c '[.[].name|ascii_downcase]' <<<"$BODY")" "$(jq -c '[.[].name|ascii_downcase]|sort' <<<"$BODY")"
    req GET "/labels?per_page=1"
    expect_eq "label list per_page" "$(jqb length)" 1
}

# nginx re-resolves workers every few seconds; wait until a request gets through
wait_ready() {
    for _ in $(seq 30); do
        [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "$BASE/health")" == 200 ] && return 0
        sleep 1
    done
    echo "stack not ready at $BASE"; exit 1
}

main() {
    wait_ready
    local tests=("$@")
    [ ${#tests[@]} -eq 0 ] && tests=($(declare -F | awk '{print $3}' | grep '^test_' | grep -v '^test_manual_'))
    for t in "${tests[@]}"; do echo "$t"; "$t"; done
    echo "failures: $FAILS"
    exit "$FAILS"
}
main "$@"
