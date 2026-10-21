#!/usr/bin/env bash
# Load the demo data (link-issues.json) through the public API, like any client:
# labels first, then each issue with its labels and comments, then close the
# ones that are closed upstream. Run against an empty database:
#   docker compose down -v && docker compose up -d --build --scale worker=3 --wait
#   db/seed/load.sh
set -euo pipefail
BASE=${BASE:-http://localhost:8080}
DATA="$(dirname "$0")/link-issues.json"

post() { curl -sf -X "$1" "$BASE$2" -H 'Content-Type: application/json' --data-binary "$3"; }

jq -c '.labels[]' "$DATA" | while read -r label; do
    post POST /labels "$label" >/dev/null
done

jq -c '.issues[]' "$DATA" | while read -r issue; do
    number=$(post POST /issues "$(jq -c '{title, body, labels}' <<<"$issue")" | jq .number)
    jq -c '.comments[] | {body: .}' <<<"$issue" | while read -r comment; do
        post POST "/issues/$number/comments" "$comment" >/dev/null
    done
    if [ "$(jq -r .state <<<"$issue")" = closed ]; then
        post PATCH "/issues/$number" "$(jq -c '{state, state_reason: (.state_reason // "completed")}' <<<"$issue")" >/dev/null
    fi
done

echo "loaded $(jq '.labels|length' "$DATA") labels and $(jq '.issues|length' "$DATA") issues from $(jq -r .source "$DATA")"
