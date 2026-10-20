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
