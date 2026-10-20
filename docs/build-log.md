# Build log

A step-by-step record of building this stack, for writing the blog post from. One section per step: **Did** (what and why), **Commands** (exact, copy-pasteable), **Broke** (each failure: symptom, cause, fix), **Commit** (message; the hash is in `git log`).

## Task 0: Start the repo

**Did:** Created an empty git repository with a `.gitignore` and this log. Nothing to run yet.

**Commands:**
```bash
git init -b main
```

**Broke:** nothing.

**Commit:** `Start the issues web service repo`

## Task 1: Prove the plumbing

**Did:** Before writing any service, checked that Dyalog can talk to Postgres from inside a container. The worker image is plain Debian plus four things: Dyalog's own `.deb` from dyalog.com, `unixodbc` and `odbc-postgresql` from apt, and Stark + Jarvis (two source files from GitHub, pinned to Stark v0.2.4). `worker/hello-db.apls` connects with SQAPL (no DSN file: the connection string names the driver), round-trips a string, lets Postgres build a JSON document, and provokes an error to see what one looks like.

**Commands:**
```bash
docker compose build worker
docker compose run --rm worker      # runs dyalogscript /worker/hello-db.apls
```
Expected:
```
CONNECT 0
ROUNDTRIP 1
JSON {"n":null,"t":"⍳⍴ café it's; --x"}
ERROR 4 SQLSTATE 42P01
```

**Broke:**
- `SELECT 'abc'::text` → `syntax error at or near ":"`. SQAPL uses colons to mark bind variables (`:<C100:`), so Postgres's `::` cast shorthand is eaten. Use `CAST(x AS text)`.
- `é` in the SQL text itself arrived at Postgres as the single byte `0xe9`, and `⍳` gave SQAPL error `10081 Length error`. Don't fix: never put data in SQL text. Every value goes in as a bind variable, which is also what makes `it's; --x` harmless.
- Bound text came back as UTF-8 bytes shown as Latin-1 (`â\u008D³` for `⍳`). Fix: declare the ODBC side as wide. `:<C100(W):` for input, `:>C100(W):` or `:>C100000(Q):` (wide long text) for output. APL type `C`, ODBC type in brackets.
- A long result with an unsized output declaration was silently cut at 8190 characters (return code `¯1`, a warning). Fix: always size output declarations, e.g. `:>C1000000(Q):`.
- Emoji (anything outside Unicode's Basic Multilingual Plane, e.g. 🚀) are lost in both directions; SQAPL passes wide text as UCS-2. APL glyphs and accented letters are fine. Accepted as a documented limitation; tests use BMP text only.
- `⎕←` output from `dyalogscript` in a container had no line breaks between lines. Used `⍞←text,⎕UCS 10` instead.
- `SQA.Do` returns `rc cursor (⊂matrix) status`. One `⊃` too many and you're looking at the first character of the first cell.

**Commit:** `Worker image talks to Postgres through SQAPL`

## Task 2: Schema

**Did:** Ported the skis schema to Postgres in one file, `db/init/01-schema.sql`, which the official `postgres` image runs automatically on an empty database (anything in `/docker-entrypoint-initdb.d`). Four tables (`issues`, `labels`, `issue_labels`, `comments`), a trigger that keeps `updated_at` current, and three views (`issue_doc`, `label_doc`, `comment_doc`) that build each GitHub-shaped JSON document with `json_build_object`. Timestamp formatting, label lists and comment counts all happen here, so the APL side never shapes a response.

Dropped from skis: issue `type`, soft delete, issue links and full-text search, since GitHub's Issues API has no simple equivalent. `state_reason` follows GitHub (`completed`, `not_planned`, `duplicate`, `reopened`).

**Commands:**
```bash
docker compose down -v                  # -v: drop the data volume so the init script runs again
docker compose up -d --wait postgres
docker compose exec postgres psql -U issues -d issues -c "INSERT INTO issues (title) VALUES ('x')"
docker compose exec postgres psql -U issues -d issues -tA -c "SELECT doc FROM issue_doc"
```
Expected:
```
{"number" : 1, "title" : "x", "body" : null, "state" : "open", "state_reason" : null, "labels" : [], "comments" : 0, "created_at" : "2026-10-20T15:49:41Z", ...}
```
The constraints do the validation work as well: inserting labels `Bug` and `bug` fails (case-insensitive unique index), and closing an issue without a `closed_at` fails a CHECK.

**Broke:** nothing.

**Commit:** `Postgres schema for issues, labels and comments`

## Task 3: A service behind nginx

**Did:** The first real service, with one route (`/health`), running behind nginx. Four small APL files:
- `worker/app/Run.apls` loads Stark and Jarvis, then our three namespaces, then calls `Service.Start`.
- `Db.apln` is the only code that knows SQAPL. `Db.Do` runs a statement with bind variables and returns the rows; `Db.Doc` runs a query whose single column is a JSON document and returns it parsed. A SQL error is signalled with `EN 500` and the SQLSTATE as its message. A lost connection (SQLSTATE class `08`) ends the process, and compose restarts the worker.
- `Api.apln` holds the handlers. `Health` runs `SELECT 1`, so "healthy" means "can reach the database".
- `Service.apln` holds the Stark route table and the server settings.

nginx is the only service with a port on the host. Its whole config is an `upstream` block that names the `worker` service. `test/smoke.sh` is a plain bash + curl + jq test script that talks to nginx exactly as a client would.

**Commands:**
```bash
docker compose up -d --build --wait
test/smoke.sh
curl -s localhost:8080/health          # {"status":"ok"}
curl -s localhost:8080/nope            # {"message":"Not Found"}
curl -s localhost:8080/openapi.json    # generated by Stark from the route table
```

**Broke:**
- `VALUE ERROR: Undefined name: Db` inside `Service.Start`. Code in a namespace doesn't automatically see its siblings in `#`; write `#.Db`.
- Right after `docker compose up --build` replaced the worker, the smoke tests got nginx's `502 Bad Gateway` page: nginx was still sending to the old container's address for up to 5 seconds (`resolver ... valid=5s`). The test script now waits until `/health` answers through nginx before it starts.

**Commit:** `Stark service skeleton behind nginx`

## Task 4: Labels

**Did:** The five label endpoints (`GET/POST /labels`, `GET/PATCH/DELETE /labels/{name}`), with tests first in `test/smoke.sh`. Each handler checks its input, runs one SQL statement with bind variables, and returns the document Postgres built. Postgres does the rest: defaults (`color` `ededed`), case-insensitive name lookup and uniqueness (`lower(name)` index), sorting. A duplicate name comes back from Postgres as SQLSTATE `23505`, and the handler turns that into GitHub's `422 already_exists`. Stark's error hook (`OnErrorFn`) logs any unexpected handler error to `docker compose logs worker` and answers `500`.

**Commands:**
```bash
docker compose up -d --build --wait
curl -s -X POST localhost:8080/labels -H 'Content-Type: application/json' -d '{"name":"bug","color":"d73a4a"}'
curl -s localhost:8080/labels/BUG
curl -s -X PATCH localhost:8080/labels/bug -H 'Content-Type: application/json' -d '{"new_name":"defect"}'
curl -s -X DELETE -w '%{http_code}\n' localhost:8080/labels/defect     # 204
test/smoke.sh
```

**Broke:**
- `DELETE … RETURNING id` (and `UPDATE`) that matched no rows → ODBC `HY010 Function sequence error` from psqlODBC, instead of an empty result. Fix: wrap the write in a CTE so ODBC sees an ordinary query: `WITH d AS (DELETE … RETURNING id) SELECT id FROM d`.
- `INDEX ERROR` in three places that chose between two values with `(condition)⊃a b`, which only works with `⎕IO←0`. Namespaces start with `⎕IO←1`. Replaced with plain `:If`.
- `diamonds are not permitted in this expression` for a namespace literal `(resource:resource ⋄ field:field ⋄ code:code)` inside a function. Built it with `⎕NS` instead.
- `ns.⎕NC⊂name` returns `2.1` for a variable, not `2`.
- Every list request failed with SQAPL `10081` (length error): `Db.Doc('SELECT …'),limit offset` glued the two numbers onto the SQL string. It must be `Db.Doc(⊂'SELECT …'),limit offset`.
- JSON key order: Jarvis re-encodes the result with `⎕JSON`, which writes keys alphabetically, so the order Postgres chose is lost. JSON key order has no meaning, so this was left as it is.

**Commit:** `Labels endpoints`

## Task 5: Issues

**Did:** The issue endpoints: `GET/POST /issues`, `GET/PATCH /issues/{number}`, and the labels on an issue (`GET/POST /issues/{number}/labels`, `DELETE /issues/{number}/labels/{name}`). More of the work moved into Postgres, where it fits naturally:
- a trigger (`issue_state_rules`) holds GitHub's rules for closing and reopening: closing sets `closed_at` and defaults `state_reason` to `completed`, and reopening clears `closed_at` and sets `reopened`;
- `set_issue_labels(number, names, replace)` attaches labels by name, and changes nothing if any name is unknown;
- `list_issues(state, labels, limit, offset)` and `list_labels(limit, offset)` return a whole page as one JSON array;
- `update_issue(...)` changes only the fields that were sent.

The APL handlers now do three things: read and check the request, call SQL, return the document. The only "business logic" left in APL is input validation (which `state` values are allowed, for example), and that is where your own rules would go.

**Commands:**
```bash
docker compose down -v && docker compose up -d --build --wait     # -v: schema changed
curl -s -X POST localhost:8080/issues -H 'Content-Type: application/json' -d '{"title":"⍳ fails on empty","labels":["bug"]}'
curl -s -X PATCH localhost:8080/issues/1 -H 'Content-Type: application/json' -d '{"state":"closed"}'
curl -s 'localhost:8080/issues?state=all&labels=bug&per_page=10'
test/smoke.sh
```

**Broke:** nothing on the first run: the lessons from Task 4 (`⊂` around the SQL, CTEs around writes, `:If` instead of indexing) carried over.

**Commit:** `Issues endpoints`

## Task 6: Comments

**Did:** `GET/POST /issues/{number}/comments`. It's the same pattern again: check that the issue exists and that the body is present, `INSERT … RETURNING id`, then return the `comment_doc` document. Listing is one more SQL function, `list_comments(number, limit, offset)`, oldest first. The issue's `comments` count comes from the `issue_doc` view, so it was already right.

**Commands:**
```bash
docker compose down -v && docker compose up -d --build --wait
curl -s -X POST localhost:8080/issues/1/comments -H 'Content-Type: application/json' -d '{"body":"⍝ reproduced"}'
curl -s localhost:8080/issues/1/comments
test/smoke.sh
```

**Broke:** nothing.

**Commit:** `Comments endpoints`

## Task 7: Scaling, X-Worker and recovery

**Did:** Showed the load balancing at work. nginx adds an `X-Worker` header with the address of the worker that answered (`add_header X-Worker $upstream_addr`). That's one line of nginx config and no APL. Because nginx re-resolves the `worker` name every 5 seconds, scaling a running stack up or down needs no nginx restart. Recovery comes from standard pieces too: when Postgres goes away, a worker's next query fails with SQLSTATE `08S01`, `Db` ends the process, and compose's `restart: unless-stopped` starts a fresh worker that reconnects.

**Commands:**
```bash
docker compose up -d --scale worker=3 --wait
for i in 1 2 3 4 5 6; do curl -sI localhost:8080/health | grep X-Worker; done   # three different addresses
docker compose up -d --scale worker=5 --wait     # nginx picks the new ones up by itself
docker compose restart postgres                  # workers exit, restart and reconnect
docker compose logs worker | grep 'Lost database connection'
test/smoke.sh                                    # includes test_x_worker
test/smoke.sh test_manual_rescale test_manual_postgres_restart   # these change the running stack
```

**Broke:**
- The first restart test passed without testing anything. The requests it sent "after" the restart were answered before Postgres had gone down. The test now records Postgres's start time and waits until it changes, then requires 12 requests in a row to succeed.
- After a Postgres restart, each worker's first request gets SQLSTATE `HY000` (a 500), and only the next one reports the lost connection (`08S01`) that makes the worker exit. So clients can see one error per worker during recovery. Accepted for a demo; a production service would check the connection before retrying.
- Just after workers are replaced, nginx can take up to 5 seconds to see all of them again, so a test that requires requests to spread across workers can fail if it runs immediately.

**Commit:** `Scale workers behind nginx and show which one answered`
