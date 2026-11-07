# Schrodinger

Single-user to-do outline across multiple projects. Tasks are assigned to the human or the AI. A master harness spawns one sub-agent process per active project; sub-agents execute their AI tasks as drafts, file proposals, and write a daily digest. The human approves, rejects, reassigns, reorders, and can undo any AI state change.

## Run

```
npm install
npm run dev        # seeds sample projects on first run, serves http://localhost:3000
npm test
```

Without `ANTHROPIC_API_KEY` the harness uses a deterministic mock LLM. Copy `.env.example` to `.env` (or export the variables) to use the Claude API. Node ≥ 22.13 (uses built-in `node:sqlite`).

## Model

- `nodes` table: projects (depth 0, with goal / success criteria / constraints / status) and tasks (nested arbitrarily, with assignee, state, due, deps, acceptance note, artifact).
- States: `todo → in_progress → review → done`, plus `blocked`.
- Progress per project = done leaf tasks / leaf tasks.

## Division of labor

| | Human | AI |
|---|---|---|
| Executes task | yes | only its own `ai` + `todo` leaf tasks whose deps are `done` |
| Output | — | draft artifact attached to task; task moves to `review` |
| Structural change (new/split/reassign tasks) | direct | proposal to Inbox; applied only on Accept |
| External action (send, post, commit) | yes | never — draft only |

Rejecting a draft returns it to `todo` with your note appended; the next run redrafts with the note in context.

## Harness

`harness/index.js` runs every `HARNESS_INTERVAL_MS` and on demand (`Run harness now`, or per-project `Run now`). For each active project it spawns `harness/agent.js <project_id>` as a child process. Each agent:

1. Executes up to `MAX_TASKS_PER_RUN` ready AI tasks → `review`.
2. Flags blocked chains and AI tasks waiting on human tasks.
3. Flags stale tasks (no activity in `STALE_DAYS`).
4. Proposes decompositions, new tasks, reassignments (heuristics + model when live).
5. Writes the project's daily digest: done / in progress / blocked / needs you.

Paused or archived projects are skipped. Every AI action is logged in `activity` with an undo payload.

## UI

- Outline: `Enter` sibling, `Tab`/`Shift+Tab` nest/unnest, `Alt+↑/↓` reorder, `Backspace` on empty deletes, `@ai` / `@me` in a title assigns, drag ⋮ to reparent.
- Side panel: Inbox (proposals), Review (drafts), Selected (fields, deps, artifact, activity + undo), Digest, Activity.
- Filters: Mine / AI's / Needs review / Blocked / Due this week, plus a mode filter.
- Modes: `call`, `errand`, `email`, `write`, `research`, `meeting`, `admin`, `other`. Set via `#call` etc. in a title, the mode chip, or the Selected panel. **Batch by mode** flattens open leaf tasks across all active projects into mode groups (sorted by due date) so similar work can be done in one sitting; checkboxes work there too.

## Layout

```
server/db.js      data layer (node:sqlite)
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
| `list_files` / `read_file` / `write_file` | jailed to `workspace/<project_id>/` |
| `finish` | submits the draft (+ questions for the human) |

There is no tool that sends, posts, commits, or contacts anyone. Without an API key a scripted mock model drives the same loop.

## Not in this prototype

Auth, multi-user, real-time push (UI polls every 8 s), web search (only fetch), per-project token budgets.
