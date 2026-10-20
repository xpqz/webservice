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
