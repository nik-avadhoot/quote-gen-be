# CFB Quotation Master — Backend

Stateless Flask API for the CFB Quotation Operating System (APSPL, CFB Division).
Its only job is to fill the Excel master template with quote data posted by the
frontend and return the workbook as a download.

Frontend repo: https://github.com/nik-avadhoot/quote-gen-fe

## Structure

```
├── server.py                     # Flask app — all routes, and the Vercel entry point
├── vercel.json                   # Routes every path to the Flask app
├── requirements.txt              # Pinned Python dependencies
├── schema.sql                    # SQLite schema (design reference — unused, see below)
├── CFB_Quotation_Master_v7.xlsx  # Excel master template
└── docs/                         # Costing manual & project brief
```

## API

| Route | Method | Description |
|-------|--------|-------------|
| `/health` | GET | Confirms the server is up and the Excel template is present |
| `/export` | POST | Fills the template from posted JSON, returns an `.xlsx` download |

## Local development

```bash
python -m venv venv && venv\Scripts\activate.bat
pip install -r requirements.txt
python server.py            # → http://localhost:3001
```

### ⚠️ OPEN QUESTION — a running process cannot be identified, so backend verification is unfalsifiable

**Read this before verifying any backend change.**

Nothing exposed by a running server says *which code it is running*:

* the startup banner prints `v2.0` — a **hardcoded constant**, unchanged across every commit
* `/health` returns `ok`, `template`, `path`, `supabase` — **no version, no commit SHA**
* there is no `__version__` anywhere in the codebase
* `server.py` ends in `app.run(port=3001, debug=False)` — **the reloader is OFF**, so a running
  process is frozen at whatever it loaded at startup and never picks up an edit on disk

**The cost, stated plainly: without a version signal, *"I restarted it"* is an assertion nobody can
check** — not the person who said it, and not a reviewer afterwards. A verification run against a
stale process is indistinguishable from one against a fixed process, and both produce a
confident-looking result.

This is not hypothetical. During the 2026-08 defect pass a backend fix was about to be tested
against a process that could not have contained it — the fix was uncommitted on disk and the
reloader was off — and the test would have returned a clean "no difference" that read as evidence
of a defect in correct code. It was caught by reading the `app.run` line, not by anything the server
reported.

**Suggested fix, trivial and NOT RULED:** put a commit SHA or build stamp in `/health` and in the
startup banner. Left open deliberately — it is small but carries a design question (where the
stamp comes from in a Vercel build versus a local run), and it was out of scope for the pass that
found it.

Until then: **restart before verifying, and treat every backend result as provisional on that.**

## Environment

| Variable | Required | Description |
|----------|----------|-------------|
| `CORS_ORIGINS` | Optional | Comma-separated allowed browser origins. Defaults to `https://quote-gen-fe.vercel.app` plus the local Vite dev server. Set it to override — e.g. to add a custom domain or a preview URL. |

## Deploying to Vercel

Import this repo — no configuration needed. `vercel.json` builds `server.py`
with `@vercel/python` and routes every path to it.

Note the config uses `builds`/`routes` rather than `rewrites`. A `rewrite`
*replaces* the request path, so the Flask app would receive the rewrite
destination instead of `/health` or `/export` and match no route. `routes`
hands the WSGI app the original path.

The default CORS origins already cover `https://quote-gen-fe.vercel.app`. Set
`CORS_ORIGINS` under Project Settings → Environment Variables only if the
frontend lives somewhere else — a custom domain, or a preview deployment, which
gets its own unique `*.vercel.app` domain.

Verify with `GET /health` — it must report `"template": true`.

Note: Vercel Hobby caps function execution at 10s. Loading and saving the 77 KB
template fits comfortably, but a cold start plus that work can approach the
limit. The frontend has a client-side export fallback if a request times out.

## No database

There is no database. All quote state lives in the browser's `localStorage`,
with JSON backup/restore in the frontend.

`schema.sql` is a forward-looking design document — no code reads or writes it.
When persistence is added, note that Vercel's filesystem is read-only at
runtime: a committed SQLite file can be read (open it with
`mode=ro&immutable=1`, since the schema's WAL mode needs directory write access)
but never written. Durable storage needs a hosted database.
