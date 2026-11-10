# Schrodinger

Single-user to-do outline across multiple projects. Tasks are assigned to the human or the AI. A master harness spawns one sub-agent process per active project; sub-agents execute their AI tasks as drafts, file proposals, and write a daily digest. The human approves, rejects, reassigns, reorders, and can undo any AI state change.

## Run

```
npm install
npm run dev        # seeds sample projects on first run, serves http://localhost:3000
npm test
```

Without `ANTHROPIC_API_KEY` the harness uses a deterministic mock LLM. Copy `.env.example` to `.env` (or export the variables) to use the Claude API. Node ≥ 22.

## Native app

`apple/` holds the SwiftUI iOS/macOS app: all data on device (SwiftData, optional iCloud sync), AI calls from the device (Apple Intelligence on-device or Claude with a Keychain-stored key), EventKit calendar hooks. See `apple/README.md`.

## Deploy

Storage is Postgres. With `DATABASE_URL` unset the app runs an embedded Postgres (PGlite) — in memory by default, on disk with `PGLITE_DIR`. Set `APP_PASSWORD` before exposing it; a login page then gates the UI and API (the iCal feed stays token-gated).

- **Vercel** (primary): `api/index.js` serves the app as one function; `vercel.json` rewrites all routes to it and schedules `/api/harness/cron` daily at 17:00 UTC (Hobby plan allows daily only; Pro allows hourly — edit `vercel.json`). Env: `DATABASE_URL` (Supabase/Neon pooled URL), `APP_PASSWORD`, `CRON_SECRET`, optional `ANTHROPIC_API_KEY`. Sub-agents run in-process inside the cron invocation (`maxDuration` 300 s). The static `public/` folder is only `logo.svg`; `index.html` is served by Express so the login gate covers it.

- **Fly.io**: `fly launch --copy-config --no-deploy` → `fly volumes create data --size 1` → `fly secrets set APP_PASSWORD=… ANTHROPIC_API_KEY=…` → `fly deploy`. Config in `fly.toml` (volume at `/data`, machine never auto-stops so the harness keeps its schedule).
- **Render**: `render.yaml` blueprint (Docker, 1 GB disk at `/data`). Set the two secrets in the dashboard.
- **Railway**: `railway.json`; add a volume mounted at `/data` and the two variables.
- **Any Docker host**: `docker build -t schrodinger . && docker run -p 3000:3000 -v schrodinger-data:/data -e APP_PASSWORD=… -e ANTHROPIC_API_KEY=… schrodinger` (embedded Postgres persisted under `/data`; or set `DATABASE_URL`).

Health check: `GET /healthz`.

## Model

- `nodes` table: projects (depth 0, with goal / success criteria / constraints / status) and tasks (nested arbitrarily, with assignee, state, due, deps, acceptance note, artifact).
- States: `todo → in_progress → review → done`, plus `blocked`.
- Progress per project = done leaf tasks / leaf tasks.

## Division of labor

| | Human | AI |
|---|---|---|
| Executes task | yes | its own `ai` + `todo` leaf tasks whose deps are `done`; the AI part of `shared` tasks |
| Shared task (`@both`) | finishes it and marks done; can send it back with a note | does the prep (research, draft, materials) → task returns as "your turn" |
| Output | — | draft artifact attached to task; task moves to `review` |
| Structural change (new/split/reassign tasks) | direct | proposal to Inbox; applied only on Accept |
| External action (send, post, commit) | yes | never — draft only |

Rejecting a draft returns it to `todo` with your note appended; the next run redrafts with the note in context.

## Harness

`harness/index.js` runs every `HARNESS_INTERVAL_MS` (long-running mode) or on each cron hit (Vercel), and on demand (`Run harness now`, or per-project `Run now`). For each active project it runs `harness/agent.js` — as a child process when a shared Postgres is configured, in-process otherwise. Each agent:

1. Executes up to `MAX_TASKS_PER_RUN` ready AI tasks → `review`.
2. Flags blocked chains and AI tasks waiting on human tasks.
3. Flags stale tasks (no activity in `STALE_DAYS`).
4. Proposes decompositions, new tasks, reassignments (heuristics + model when live).
5. Writes the project's daily digest: done / in progress / blocked / needs you.

Paused or archived projects are skipped. Every AI action is logged in `activity` with an undo payload.

## UI

- One continuous numbered outline: top-level items are projects (goal + progress inline); children numbered within each parent at any depth; items with children act as categories (no checkbox, leaf count instead).
- Outline: `Enter` sibling, `Tab`/`Shift+Tab` nest/unnest, `Alt+↑/↓` reorder, `Backspace` on empty deletes, `@ai` / `@me` in a title assigns, drag ⋮ to reparent.
- Side panel: Inbox (proposals), Review (drafts), Selected (fields, deps, artifact, activity + undo), Digest, Activity.
- Filters: Mine / AI's / Needs review / Blocked / Due this week, plus a mode filter.
- Modes: `call`, `errand`, `email`, `write`, `research`, `meeting`, `admin`, `other`. Set via `#call` etc. in a title, the mode chip, or the Selected panel. **Batch by mode** flattens open leaf tasks across all active projects into mode groups (sorted by due date) so similar work can be done in one sitting; checkboxes work there too.

## Themes

Default is the dark console theme: black background, warm pastel rail segments with rounded elbows, pill controls, and a readable normal-width sans (Inter, system fallback) rather than condensed caps. A light theme is available via the Theme button; the choice persists in the browser. Rail segments act as shortcuts (Projects → outline, Tasks → batch view, Agents → activity).

## Layout

```
server/db.js      data layer (Postgres via pg, or embedded PGlite)
api/index.js      Vercel function entry
server/app.js     REST API
server/index.js   entry
server/seed.js    sample data
harness/index.js  scheduler, spawns sub-agents
harness/agent.js  per-project sub-agent
harness/llm.js    Claude API adapter + offline mock
public/index.html single-page UI
test/             node:test suite
```

## Sub-agent tools

Each sub-agent runs an agentic loop (`harness/llm.js`, up to `AGENT_MAX_TURNS`) with these tools (`harness/tools.js`):

| tool | scope |
|---|---|
| `project_context` | goal, criteria, constraints, all tasks, existing artifacts |
| `web_fetch` | public http(s) URL → text, read-only |
| `list_files` / `read_file` / `write_file` | per-project workspace stored in the `files` table |
| `finish` | submits the draft (+ questions for the human) |

There is no tool that sends, posts, commits, or contacts anyone. Without an API key a scripted mock model drives the same loop.

## Calendar hooks

Outbound
- `GET /calendar/<token>.ics` — subscribe URL (Google / Apple / Outlook). Tasks with due dates appear as all-day events, marked `(AI)` or `✓` as they change. Token shown in the Calendar tab; rotate it there.
- `GET /api/nodes/:id.ics` — single-task "Add to calendar" file.

Inbound
- `POST /api/calendars {name, kind:'ics', url, project_id?}` — subscribe to any ICS/webcal feed (Google: calendar settings → *Secret address in iCal format*). Synced before every harness run and via `POST /api/calendars/:id/sync`. Events cached in `events`; a failing fetch keeps the last good cache and records `last_error`.
- `GET /api/events?from&to&project_id` — merged agenda.
- Project-linked calendars: upcoming events with no related task produce a `new_task` proposal ("Prepare for: …", mode `meeting`, due on the event date). Global calendars are visible to agents and digests but never spawn tasks.
- Sub-agent tool `calendar_events(from, to)`.
- Digest gets a "Today's calendar" section.

Providers live in `server/calendar.js` (`providers.ics` implemented; `google` and `caldav` are stubs with the same `fetchEvents(calendar)` interface for OAuth adapters).

## Not in this prototype

Auth, multi-user, real-time push (UI polls every 8 s), web search (only fetch), per-project token budgets, OAuth calendar providers (ICS feeds cover Google/Apple/Outlook read-only), recurring-event expansion (RRULE events are flagged but only their first instance is stored).
