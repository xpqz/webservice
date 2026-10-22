#!/usr/bin/env bash
# End-to-end tests through nginx. Normally run by test/ci.sh, which starts a
# separate test stack (own database) on port 18080, so the demo data on 8080
# is never touched. Usage: test/smoke.sh [test_name ...]  (no names: run all)
set -uo pipefail

BASE=${BASE:-http://localhost:18080}
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

# new_issue JSON -> sets NUM to the new issue's number
new_issue() { req POST /issues "$1"; NUM=$(jqb .number); }
new_label() { req POST /labels "{\"name\":\"$1\"}"; }

TITLE="⍳⍴ café it's; --x"

test_issue_create() {
    new_issue "{\"title\":\"$TITLE\"}"
    expect_eq "issue create status" "$STATUS" 201
    expect_eq "issue title round-trips" "$(jqb .title)" "$TITLE"
    expect_eq "issue state" "$(jqb .state)" open
    expect_eq "issue body null" "$(jqb .body)" null
    expect_eq "issue closed_at null" "$(jqb .closed_at)" null
    expect_eq "issue state_reason null" "$(jqb .state_reason)" null
    expect_eq "issue labels empty" "$(jq -c .labels <<<"$BODY")" "[]"
    expect_eq "issue comments zero" "$(jqb .comments)" 0
    expect_eq "issue created_at format" "$(jqb '.created_at|test("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$")')" true
    expect_eq "issue number is number" "$(jqb '.number|type')" number
}

test_issue_missing_title() {
    req POST /issues '{"body":"b"}'
    expect_eq "issue missing title status" "$STATUS" 422
    expect_eq "issue missing title error" "$(jq -cS '.errors[0]' <<<"$BODY")" '{"code":"missing_field","field":"title","resource":"Issue"}'
}

test_issue_get() {
    new_issue "{\"title\":\"get $RUN\",\"body\":\"some ⍝ body\"}"
    req GET "/issues/$NUM"
    expect_eq "issue get status" "$STATUS" 200
    expect_eq "issue get title" "$(jqb .title)" "get $RUN"
    expect_eq "issue get body" "$(jqb .body)" "some ⍝ body"
    for bad in abc 0 99999999 -1 1.5; do
        req GET "/issues/$bad"
        expect_eq "issue get $bad status" "$STATUS" 404
        expect_eq "issue get $bad message" "$(jqb .message)" "Not Found"
    done
}

test_issue_update_fields() {
    new_issue "{\"title\":\"old $RUN\"}"
    req PATCH "/issues/$NUM" '{"title":"new title","body":"new body"}'
    expect_eq "issue update status" "$STATUS" 200
    expect_eq "issue update title" "$(jqb .title)" "new title"
    expect_eq "issue update body" "$(jqb .body)" "new body"
    req PATCH /issues/99999999 '{"title":"x"}'
    expect_eq "issue update unknown" "$STATUS" 404
}

test_issue_close_reopen() {
    new_issue "{\"title\":\"close $RUN\"}"
    req PATCH "/issues/$NUM" '{"state":"closed"}'
    expect_eq "close status" "$STATUS" 200
    expect_eq "close state" "$(jqb .state)" closed
    expect_eq "close reason defaults" "$(jqb .state_reason)" completed
    expect_eq "close sets closed_at" "$(jqb '.closed_at != null')" true
    req PATCH "/issues/$NUM" '{"state":"open"}'
    expect_eq "reopen state" "$(jqb .state)" open
    expect_eq "reopen reason" "$(jqb .state_reason)" reopened
    expect_eq "reopen clears closed_at" "$(jqb .closed_at)" null
    req PATCH "/issues/$NUM" '{"state":"closed","state_reason":"not_planned"}'
    expect_eq "close not_planned" "$(jqb .state_reason)" not_planned
    req PATCH "/issues/$NUM" '{"state":"bogus"}'
    expect_eq "bad state status" "$STATUS" 422
    expect_eq "bad state field" "$(jqb '.errors[0].field')" state
    expect_eq "bad state code" "$(jqb '.errors[0].code')" invalid
}

test_issue_labels() {
    new_label "l1-$RUN"; new_label "l2-$RUN"
    new_issue "{\"title\":\"labels $RUN\",\"labels\":[\"l1-$RUN\"]}"
    expect_eq "create with label" "$(jqb '.labels[0].name')" "l1-$RUN"
    req POST "/issues/$NUM/labels" "{\"labels\":[\"L2-$RUN\"]}"
    expect_eq "add label status" "$STATUS" 200
    expect_eq "add label names" "$(jq -c '[.[].name]' <<<"$BODY")" "[\"l1-$RUN\",\"l2-$RUN\"]"
    req GET "/issues/$NUM/labels"
    expect_eq "list issue labels" "$(jqb length)" 2
    req DELETE "/issues/$NUM/labels/l1-$RUN"
    expect_eq "remove label status" "$STATUS" 200
    expect_eq "remove label remaining" "$(jq -c '[.[].name]' <<<"$BODY")" "[\"l2-$RUN\"]"
    req DELETE "/issues/$NUM/labels/l1-$RUN"
    expect_eq "remove absent label" "$STATUS" 404
    req PATCH "/issues/$NUM" '{"labels":[]}'
    expect_eq "patch clears labels" "$(jq -c .labels <<<"$BODY")" "[]"
    req POST /issues "{\"title\":\"x\",\"labels\":[\"missing-$RUN\"]}"
    expect_eq "unknown label status" "$STATUS" 422
    expect_eq "unknown label field" "$(jqb '.errors[0].field')" labels
    req GET /issues/99999999/labels
    expect_eq "labels of unknown issue" "$STATUS" 404
}

test_issue_list_filters() {
    new_label "f-$RUN"
    new_issue "{\"title\":\"f1 $RUN\",\"labels\":[\"f-$RUN\"]}"
    new_issue "{\"title\":\"f2 $RUN\",\"labels\":[\"f-$RUN\"]}"
    new_issue "{\"title\":\"f3 $RUN\",\"labels\":[\"f-$RUN\"]}"
    req PATCH "/issues/$NUM" '{"state":"closed"}'
    req GET "/issues?labels=f-$RUN"
    expect_eq "list default open" "$(jqb length)" 2
    expect_eq "list newest first" "$(jqb '.[0].title')" "f2 $RUN"
    req GET "/issues?labels=f-$RUN&state=all"
    expect_eq "list state all" "$(jqb length)" 3
    req GET "/issues?labels=f-$RUN&state=closed"
    expect_eq "list state closed" "$(jqb length)" 1
    req GET "/issues?labels=f-$RUN&state=all&per_page=1&page=2"
    expect_eq "list page 2 size" "$(jqb length)" 1
    expect_eq "list page 2 item" "$(jqb '.[0].title')" "f2 $RUN"
    req GET "/issues?state=all&per_page=1000"
    expect_eq "list per_page capped" "$(jqb 'length <= 100')" true
    req GET "/issues?labels=f-$RUN&page=abc"
    expect_eq "list bad page is page 1" "$(jqb length)" 2
    req GET "/issues?labels=f-$RUN,nope-$RUN"
    expect_eq "list all labels must match" "$(jqb length)" 0
}

test_comment_create() {
    new_issue "{\"title\":\"comments $RUN\"}"
    req POST "/issues/$NUM/comments" '{"body":"⍝ first, it'"'"'s fine"}'
    expect_eq "comment create status" "$STATUS" 201
    expect_eq "comment body" "$(jqb .body)" "⍝ first, it's fine"
    expect_eq "comment id is number" "$(jqb '.id|type')" number
    expect_eq "comment created_at format" "$(jqb '.created_at|test("Z$")')" true
    req GET "/issues/$NUM"
    expect_eq "issue counts comment" "$(jqb .comments)" 1
}

test_comment_missing_body() {
    new_issue "{\"title\":\"comments $RUN\"}"
    req POST "/issues/$NUM/comments" '{}'
    expect_eq "comment missing body status" "$STATUS" 422
    expect_eq "comment missing body error" "$(jq -cS '.errors[0]' <<<"$BODY")" '{"code":"missing_field","field":"body","resource":"IssueComment"}'
}

test_comment_list() {
    new_issue "{\"title\":\"comments $RUN\"}"
    req POST "/issues/$NUM/comments" '{"body":"one"}'
    req POST "/issues/$NUM/comments" '{"body":"two"}'
    req GET "/issues/$NUM/comments"
    expect_eq "comment list status" "$STATUS" 200
    expect_eq "comment list order" "$(jq -c '[.[].body]' <<<"$BODY")" '["one","two"]'
    req GET "/issues/$NUM/comments?per_page=1&page=2"
    expect_eq "comment list page 2" "$(jq -c '[.[].body]' <<<"$BODY")" '["two"]'
}

test_comment_unknown_issue() {
    req GET /issues/99999999/comments
    expect_eq "comments of unknown issue" "$STATUS" 404
    req POST /issues/99999999/comments '{"body":"x"}'
    expect_eq "comment on unknown issue" "$STATUS" 404
}

test_issue_list_sort_updated() {
    new_label "s-$RUN"
    new_issue "{\"title\":\"older $RUN\",\"labels\":[\"s-$RUN\"]}"; local older=$NUM
    new_issue "{\"title\":\"newer $RUN\",\"labels\":[\"s-$RUN\"]}"
    req PATCH "/issues/$older" '{"state":"closed"}'
    req GET "/issues?labels=s-$RUN&state=all"
    expect_eq "default sort is created" "$(jqb '.[0].title')" "newer $RUN"
    req GET "/issues?labels=s-$RUN&state=all&sort=updated"
    expect_eq "sort=updated puts the just-closed issue first" "$(jqb '.[0].title')" "older $RUN"
    req GET "/issues?labels=s-$RUN&state=all&sort=bogus"
    expect_eq "unknown sort falls back to created" "$(jqb '.[0].title')" "newer $RUN"
}

# conforms SCHEMA_JSON VALUE_JSON -> "true" when the value has exactly the
# schema's fields, with matching types (OpenAPI 3.0: type, nullable, items)
conforms() {
    jq -n --argjson s "$1" --argjson v "$2" '
      def jtype: if type == "number" then (if . == floor then "integer" else "number" end) else type end;
      def ok($s):
        if . == null then ($s.nullable == true)
        elif $s.type == "array" then (type == "array" and all(.[]; ok($s.items)))
        elif $s.type == "object" then
          (type == "object" and (keys == ($s.properties | keys))
           and (. as $v | all($s.properties | to_entries[]; . as $p | $v[$p.key] | ok($p.value))))
        elif $s.type == "number" then (type == "number")
        else (jtype == $s.type) end;
      $v | ok($s)'
}

SPEC=""
spec_schema() {   # spec_schema PATH METHOD STATUS
    [ -n "$SPEC" ] || SPEC=$(curl -s "$BASE/openapi.json")
    jq -c --arg p "$1" --arg m "$2" --arg s "$3" '.paths[$p][$m].responses[$s].content["application/json"].schema' <<<"$SPEC"
}

test_openapi_metadata() {
    local spec; spec=$(curl -s "$BASE/openapi.json")
    expect_eq "every operation has a summary" "$(jq '[.paths[][] | has("summary")] | all' <<<"$spec")" true
    expect_eq "list issues query parameters" "$(jq -c '[.paths["/issues"].get.parameters[].name] | sort' <<<"$spec")" '["labels","page","per_page","sort","state"]'
    expect_eq "issue number is an integer" "$(jq -r '.paths["/issues/{number}"].get.parameters[0].schema.type' <<<"$spec")" integer
    expect_eq "create issue responses" "$(jq -c '.paths["/issues"].post.responses | keys' <<<"$spec")" '["201","422"]'
    expect_eq "create issue body requires title" "$(jq -c '.paths["/issues"].post.requestBody.content["application/json"].schema.required' <<<"$spec")" '["title"]'
    expect_eq "delete label answers 204" "$(jq -c '.paths["/labels/{name}"].delete.responses | keys' <<<"$spec")" '["204","404"]'
    local body='.paths["/issues"].post.requestBody.content["application/json"].schema.properties'
    expect_eq "request body field may be null" "$(jq "$body.body.nullable" <<<"$spec")" true
    expect_eq "request title may not be null" "$(jq "$body.title.nullable // false" <<<"$spec")" false
    expect_eq "request text has GitHub's length limit" "$(jq "$body.body.maxLength" <<<"$spec")" 65536
    expect_eq "label colour may be null" "$(jq '.paths["/labels"].post.requestBody.content["application/json"].schema.properties.color.nullable' <<<"$spec")" true
}

test_responses_match_spec() {
    new_label "spec-$RUN"
    req POST /labels "{\"name\":\"spec2-$RUN\",\"description\":\"d\"}"
    expect_eq "POST /labels 201 matches spec" "$(conforms "$(spec_schema /labels post 201)" "$BODY")" true
    new_issue "{\"title\":\"spec $RUN\",\"labels\":[\"spec-$RUN\"]}"
    expect_eq "POST /issues 201 matches spec" "$(conforms "$(spec_schema /issues post 201)" "$BODY")" true
    req PATCH "/issues/$NUM" '{"state":"closed"}'
    expect_eq "PATCH /issues/{number} 200 matches spec" "$(conforms "$(spec_schema '/issues/{number}' patch 200)" "$BODY")" true
    req POST "/issues/$NUM/comments" '{"body":"c"}'
    expect_eq "POST comment 201 matches spec" "$(conforms "$(spec_schema '/issues/{number}/comments' post 201)" "$BODY")" true
    req GET "/issues/$NUM/comments"
    expect_eq "GET comments 200 matches spec" "$(conforms "$(spec_schema '/issues/{number}/comments' get 200)" "$BODY")" true
    req GET "/issues?labels=spec-$RUN&state=all"
    expect_eq "GET /issues 200 matches spec" "$(conforms "$(spec_schema /issues get 200)" "$BODY")" true
    req GET "/issues/$NUM/labels"
    expect_eq "GET issue labels 200 matches spec" "$(conforms "$(spec_schema '/issues/{number}/labels' get 200)" "$BODY")" true
    req GET "/labels?per_page=5"
    expect_eq "GET /labels 200 matches spec" "$(conforms "$(spec_schema /labels get 200)" "$BODY")" true
    req GET /issues/99999999
    expect_eq "404 matches spec" "$(conforms "$(spec_schema '/issues/{number}' get 404)" "$BODY")" true
    req POST /issues '{}'
    expect_eq "422 matches spec" "$(conforms "$(spec_schema /issues post 422)" "$BODY")" true
    req GET /health
    expect_eq "GET /health matches spec" "$(conforms "$(spec_schema /health get 200)" "$BODY")" true
}


test_writes_are_all_or_nothing() {
    new_label "aon-$RUN"
    req GET "/issues?state=all&per_page=100&labels=aon-$RUN"; local before; before=$(jqb length)
    req POST /issues "{\"title\":\"aon $RUN\",\"labels\":[\"aon-$RUN\",\"missing-$RUN\"]}"
    expect_eq "create with an unknown label refused" "$STATUS" 422
    req GET "/issues?state=all&per_page=100&labels=aon-$RUN"
    expect_eq "nothing created" "$(jqb length)" "$before"
    new_issue "{\"title\":\"aon keep $RUN\"}"
    req PATCH "/issues/$NUM" "{\"title\":\"changed\",\"labels\":[\"missing-$RUN\"]}"
    expect_eq "update with an unknown label refused" "$STATUS" 422
    req GET "/issues/$NUM"
    expect_eq "title left unchanged" "$(jqb .title)" "aon keep $RUN"
    req PATCH /issues/99999999 "{\"labels\":[\"missing-$RUN\"]}"
    expect_eq "unknown issue is 404 before label checks" "$STATUS" 404
    req POST /issues/99999999/labels "{\"labels\":[\"aon-$RUN\"]}"
    expect_eq "add labels to unknown issue" "$STATUS" 404
}

# A JSON string of n characters
long_text() { python3 -c "import sys; print('x'*int(sys.argv[1]))" "$1"; }

test_null_fields() {
    new_issue "{\"title\":\"nulls $RUN\",\"body\":null}"
    expect_eq "create body null stays null" "$(jqb .body)" null
    req PATCH "/issues/$NUM" '{"title":null}'
    expect_eq "patch title null keeps title" "$(jqb .title)" "nulls $RUN"
    req POST /labels "{\"name\":\"nl-$RUN\",\"color\":null,\"description\":null}"
    expect_eq "label null color defaults" "$(jqb .color)" ededed
    expect_eq "label null description" "$(jqb .description)" null
    req PATCH "/labels/nl-$RUN" '{"new_name":null}'
    expect_eq "label null new_name keeps name" "$(jqb .name)" "nl-$RUN"
}

test_wrong_types() {
    new_issue "{\"title\":\"types $RUN\"}"
    req PATCH "/issues/$NUM" '{"body":5}'
    expect_eq "number body status" "$STATUS" 422
    expect_eq "number body field" "$(jqb '.errors[0].field')" body
    req PATCH "/issues/$NUM" '{"body":["a"]}'
    expect_eq "array body status" "$STATUS" 422
    req POST /labels "{\"name\":\"wt-$RUN\",\"color\":5}"
    expect_eq "number color status" "$STATUS" 422
    expect_eq "number color field" "$(jqb '.errors[0].field')" color
    for bad in '"bug"' 5 null '{"a":1}'; do
        req POST /issues "{\"title\":\"t\",\"labels\":$bad}"
        expect_eq "labels $bad status" "$STATUS" 422
        expect_eq "labels $bad field" "$(jqb '.errors[0].field')" labels
        req POST "/issues/$NUM/labels" "{\"labels\":$bad}"
        expect_eq "add labels $bad status" "$STATUS" 422
    done
}

test_too_long() {
    req POST /issues "{\"title\":\"t\",\"body\":\"$(long_text 65537)\"}"
    expect_eq "body over 65536 status" "$STATUS" 422
    expect_eq "body over 65536 field" "$(jqb '.errors[0].field')" body
    req POST /issues "{\"title\":\"t\",\"body\":\"$(long_text 150000)\"}"
    expect_eq "body 150000 status" "$STATUS" 422
    req POST /issues "{\"title\":\"long ok $RUN\",\"body\":\"$(long_text 65536)\"}"
    expect_eq "body of 65536 accepted" "$STATUS" 201
    expect_eq "body of 65536 stored" "$(jqb '.body|length')" 65536
}

test_large_list() {
    new_label "big-$RUN"
    local b; b=$(long_text 65536)
    for i in $(seq 18); do
        req POST /issues "{\"title\":\"big $i\",\"body\":\"$b\",\"labels\":[\"big-$RUN\"]}"
    done
    req GET "/issues?labels=big-$RUN"
    expect_eq "large list status" "$STATUS" 200
    expect_eq "large list count" "$(jqb length)" 18
}

CONSOLE=${CONSOLE:-http://localhost:13000}

test_console_served() {
    local status page
    status=$(curl -s -o "$TMP/console" -w '%{http_code}' "$CONSOLE/")
    expect_eq "console page status" "$status" 200
    expect_eq "console page is the Vue app" "$(grep -c 'id="app"' "$TMP/console")" 1
    status=$(curl -s -o /dev/null -w '%{http_code}' "$CONSOLE/app.js")
    expect_eq "console app.js served" "$status" 200
}

test_cors_for_console() {
    curl -s -D "$TMP/h" -o /dev/null -X OPTIONS -H "Origin: $CONSOLE" \
         -H 'Access-Control-Request-Method: PATCH' -H 'Access-Control-Request-Headers: content-type' "$BASE/issues/1"
    HEADERS=$(tr -d '\r' < "$TMP/h")
    expect_eq "preflight allows origin" "$(grep -ci '^access-control-allow-origin: ' <<<"$HEADERS")" 1
    expect_eq "preflight allows PATCH" "$(grep -i '^access-control-allow-methods:' <<<"$HEADERS" | grep -c PATCH)" 1
    curl -s -D "$TMP/h" -o /dev/null -H "Origin: $CONSOLE" "$BASE/issues"
    HEADERS=$(tr -d '\r' < "$TMP/h")
    expect_eq "response allows origin" "$(grep -ci '^access-control-allow-origin: ' <<<"$HEADERS")" 1
    expect_eq "browser may read X-Worker" "$(grep -i '^access-control-expose-headers:' <<<"$HEADERS" | grep -ci x-worker)" 1
}

# workers_seen N -> number of distinct X-Worker values over N requests
workers_seen() {
    for _ in $(seq "$1"); do
        req GET /health
        grep -i '^x-worker:' <<<"$HEADERS" | cut -d' ' -f2
    done | sort -u | grep -c .
}

test_x_worker() {
    req GET /health
    expect_eq "x-worker header present" "$(grep -ci '^x-worker: ' <<<"$HEADERS")" 1
    expect_eq "requests spread over workers" "$( [ "$(workers_seen 12)" -ge 2 ] && echo yes)" yes
}

# Not run by default: these change the running stack.
test_manual_rescale() {
    docker compose up -d --scale worker=1 --wait >/dev/null 2>&1; sleep 6
    expect_eq "one worker" "$(workers_seen 8)" 1
    docker compose up -d --scale worker=3 --wait >/dev/null 2>&1; sleep 6
    expect_eq "three workers, nginx not restarted" "$(workers_seen 12)" 3
}

test_manual_postgres_restart() {
    local pg before ok=""
    pg=$(docker compose ps -q postgres)
    before=$(docker inspect -f '{{.State.StartedAt}}' "$pg")
    docker compose restart postgres >/dev/null 2>&1
    for _ in $(seq 30); do      # `restart` can return before the container has restarted
        [ "$(docker inspect -f '{{.State.StartedAt}}' "$pg")" != "$before" ] && break
        sleep 1
    done
    expect_eq "postgres actually restarted" "$( [ "$(docker inspect -f '{{.State.StartedAt}}' "$pg")" != "$before" ] && echo yes)" yes
    for _ in $(seq 60); do
        req GET /health
        if [ "$STATUS" == 200 ]; then
            req POST /issues '{"title":"after restart"}'
            [ "$STATUS" == 201 ] && { ok=yes; break; }
        fi
        sleep 1
    done
    expect_eq "service recovers after postgres restart" "$ok" yes
    local good=0                # every worker back: 12 requests in a row succeed
    for _ in $(seq 60); do
        good=0
        for _ in $(seq 12); do req GET /health; [ "$STATUS" == 200 ] && good=$((good+1)); done
        [ "$good" == 12 ] && break
        sleep 1
    done
    expect_eq "all workers healthy again" "$good" 12
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
