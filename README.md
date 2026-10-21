# Issues web service

A small clone of GitHub's Issues REST API, built to show how an APL application fits into an ordinary web-service stack. It's for learning only, not for real use.

```
                  ┌──────────┐
client ──:8080──► │  nginx   │  load balancer (round-robin)
                  └────┬─────┘
            ┌──────────┼──────────┐
            ▼          ▼          ▼
        ┌────────┐ ┌────────┐ ┌────────┐
        │ worker │ │ worker │ │ worker │   Dyalog APL + Stark/Jarvis
        └───┬────┘ └───┬────┘ └───┬────┘
            └──────────┼──────────┘      SQAPL → ODBC
                       ▼
                 ┌──────────┐
                 │ postgres │  tables, rules, JSON documents
                 └──────────┘
```

Most of this is standard building blocks: the official `postgres` and `nginx` images, Docker Compose, unixODBC and the Postgres ODBC driver. The APL part (`worker/app/`) turns an HTTP request into SQL and hands back the JSON document that Postgres built. That part is where your own application logic would go.

## Licence: read this first

The worker image downloads and installs **Dyalog APL** from dyalog.com while it builds. Dyalog is free for non-commercial use but is **not free software**. By building the image you accept Dyalog's licence terms: <https://www.dyalog.com/uploads/documents/Developer_Software_Licence.pdf>. The licence also ships inside the image at `/opt/mdyalog/20.0/64/unicode/LICENSE`. This repository contains no Dyalog software. Build images locally; don't publish them.

[Stark](https://github.com/dyalog-labs/stark) (MIT licence) is pre-release software.

## Run it

You need Docker with Compose. The image builds natively on both arm64 (Apple Silicon) and x86-64.

```bash
cp .env.example .env        # optional: change the database password
docker compose up -d --build --scale worker=3 --wait
test/smoke.sh               # end-to-end tests through nginx
```

Try it:

```bash
curl -s -X POST localhost:8080/labels -H 'Content-Type: application/json' \
     -d '{"name":"bug","color":"d73a4a"}'
curl -s -X POST localhost:8080/issues -H 'Content-Type: application/json' \
     -d '{"title":"⍳ fails on an empty argument","labels":["bug"]}'
curl -s -X POST localhost:8080/issues/1/comments -H 'Content-Type: application/json' \
     -d '{"body":"Reproduced with ⍳0"}'
curl -s -X PATCH localhost:8080/issues/1 -H 'Content-Type: application/json' \
     -d '{"state":"closed"}'
curl -s 'localhost:8080/issues?state=all&labels=bug'
```

Raw responses show non-ASCII characters as escapes (`⍳` is `\u2373`). That's valid JSON; pipe through `jq` to see the characters.

Or open the **console** at <http://localhost:3000>. It's a separate client app (Vue, no build step) that runs in your browser and uses the API exactly like `curl` does. You can browse, create and edit issues and comment on them, and a request log at the bottom shows every REST call it makes, with the JSON.

Every response has an `X-Worker` header that names the worker that answered. Repeat a request and it changes.

The OpenAPI description is at <http://localhost:8080/openapi.json>, and you can load it into any Swagger UI.

Other things to try:

```bash
docker compose up -d --scale worker=5 --wait   # more workers; nginx finds them by itself
docker compose restart postgres                # a few seconds of errors, then workers reconnect on their own
docker compose logs worker
docker compose down -v                         # stop and delete the data
```

## The API

URLs, fields and status codes follow [GitHub's Issues REST API](https://docs.github.com/en/rest/issues), for one repository and without authentication:

| Method | Path |
|--------|------|
| GET, POST | `/issues` (list: `state`, `labels`, `sort` = `created`/`updated`, `per_page`, `page`) |
| GET, PATCH | `/issues/{number}` |
| GET, POST | `/issues/{number}/comments` |
| GET, POST | `/issues/{number}/labels` |
| DELETE | `/issues/{number}/labels/{name}` |
| GET, POST | `/labels` |
| GET, PATCH, DELETE | `/labels/{name}` |

Known limitations:
- Characters outside Unicode's Basic Multilingual Plane, such as emoji, are silently dropped (SQAPL passes text as UCS-2). APL symbols and accented letters are fine.
- A label whose name contains `/` can be created but not reached by name in a URL: Jarvis decodes `%2F` before Stark matches routes.
- While Postgres restarts, requests fail for a few seconds (500s and nginx 502s) until every worker has restarted and reconnected.
- JSON keys come back in alphabetical order.

## Where things are

| Path | What |
|------|------|
| `compose.yaml` | the three services |
| `nginx/nginx.conf` | load balancing |
| `db/init/01-schema.sql` | tables, rules (triggers), and the views and functions that build JSON |
| `worker/Dockerfile` | Debian + Dyalog + unixODBC + Postgres ODBC driver + Stark |
| `worker/app/Service.apln` | the route table |
| `worker/app/Api.apln` | the handlers |
| `worker/app/Db.apln` | the database connection |
| `worker/hello-db.apls` | a first check that APL can reach Postgres |
| `console/` | the browser client: `api.js` (every REST call), `app.js` (Vue components) |
| `test/smoke.sh` | end-to-end tests |
| `docs/build-log.md` | how it was built, step by step, including what went wrong |
