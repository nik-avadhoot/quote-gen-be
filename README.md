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
