// Data layer on Postgres. One `nodes` table holds projects (depth 0) and tasks (nested).
// Driver: `pg` Pool (DATABASE_URL) in production; PGlite (in-process Postgres) for tests/local when no URL.
const crypto = require('node:crypto');

const SCHEMA = `
CREATE TABLE IF NOT EXISTS nodes (
  id TEXT PRIMARY KEY,
  parent_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('project','task')),
  title TEXT NOT NULL DEFAULT '',
  goal TEXT NOT NULL DEFAULT '',
  success_criteria TEXT NOT NULL DEFAULT '',
  constraints TEXT NOT NULL DEFAULT '',
  assignee TEXT NOT NULL DEFAULT 'unassigned' CHECK (assignee IN ('human','ai','unassigned')),
  state TEXT NOT NULL DEFAULT 'todo' CHECK (state IN ('todo','in_progress','blocked','review','done')),
  project_status TEXT NOT NULL DEFAULT 'active' CHECK (project_status IN ('active','paused','archived')),
  due TEXT,
  acceptance_note TEXT NOT NULL DEFAULT '',
  mode TEXT NOT NULL DEFAULT '',
  artifact TEXT,
  position INTEGER NOT NULL DEFAULT 0,
  collapsed INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id, position);

CREATE TABLE IF NOT EXISTS deps (
  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  depends_on TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  PRIMARY KEY (node_id, depends_on)
);

CREATE TABLE IF NOT EXISTS activity (
  id SERIAL PRIMARY KEY,
  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  actor TEXT NOT NULL CHECK (actor IN ('human','ai','harness')),
  action TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  undo TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_activity_node ON activity(node_id, id);

CREATE TABLE IF NOT EXISTS inbox (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  type TEXT NOT NULL,
  summary TEXT NOT NULL,
  payload TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','accepted','dismissed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS digests (
  id SERIAL PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(project_id, day)
);

CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS calendars (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'ics',
  url TEXT NOT NULL DEFAULT '',
  project_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_synced_at TIMESTAMPTZ,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS events (
  calendar_id TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE,
  uid TEXT NOT NULL,
  title TEXT NOT NULL,
  start TEXT NOT NULL,
  "end" TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  description TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  recurring INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (calendar_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_events_start ON events(start);

CREATE TABLE IF NOT EXISTS files (
  project_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, path)
);

CREATE TABLE IF NOT EXISTS harness_runs (
  id SERIAL PRIMARY KEY,
  project_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'running',
  log TEXT NOT NULL DEFAULT ''
);
`;

const MODES = ['call', 'errand', 'email', 'write', 'research', 'meeting', 'admin', 'other'];
const uid = () => crypto.randomUUID();

// ---------- drivers ----------
async function makeDriver(url) {
  if (url) {
    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: url, max: Number(process.env.PG_POOL_MAX || 3), ssl: /localhost|127\.0\.0\.1/.test(url) ? undefined : { rejectUnauthorized: false } });
    return {
      query: (text, params = []) => pool.query(text, params).then(r => r.rows),
      tx: async fn => { const c = await pool.connect(); try { await c.query('BEGIN'); const out = await fn((t, p = []) => c.query(t, p).then(r => r.rows)); await c.query('COMMIT'); return out; } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); } },
      close: () => pool.end(),
    };
  }
  const { PGlite } = require('@electric-sql/pglite');
  const pg = new PGlite(process.env.PGLITE_DIR || undefined);
  await pg.waitReady;
  return {
    query: (text, params = []) => pg.query(text, params).then(r => r.rows),
    tx: fn => pg.transaction(t => fn((text, params = []) => t.query(text, params).then(r => r.rows))),
    close: () => pg.close(),
  };
}

async function open(url = process.env.DATABASE_URL) {
  const d = await makeDriver(url);
  for (const stmt of SCHEMA.split(';').map(s => s.trim()).filter(Boolean)) await d.query(stmt);
  return wrap(d);
}

// Normalize rows: timestamps → ISO strings so callers compare lexically as before.
const iso = v => v instanceof Date ? v.toISOString() : v;
function norm(row) { if (!row) return row; for (const k of ['created_at', 'updated_at', 'last_activity_at', 'last_synced_at', 'started_at', 'finished_at']) if (k in row) row[k] = iso(row[k]); return row; }
const one = rows => norm(rows[0]) || null;
const all = rows => rows.map(norm);

function wrap(d) {
  const q = (t, p) => d.query(t, p).then(all);
  const q1 = (t, p) => d.query(t, p).then(one);

  async function log(node_id, actor, action, detail = '', undo = null, qq = q) {
    await qq(`INSERT INTO activity (node_id, actor, action, detail, undo) VALUES ($1,$2,$3,$4,$5)`, [node_id, actor, action, detail, undo ? JSON.stringify(undo) : null]);
    await qq(`UPDATE nodes SET last_activity_at=now() WHERE id=$1`, [node_id]);
  }

  async function getNode(id) {
    const n = await q1(`SELECT * FROM nodes WHERE id=$1`, [id]);
    if (!n) return null;
    n.deps = (await q(`SELECT depends_on FROM deps WHERE node_id=$1`, [id])).map(r => r.depends_on);
    return n;
  }
  const children = parent_id => parent_id
    ? q(`SELECT * FROM nodes WHERE parent_id=$1 ORDER BY position, created_at`, [parent_id])
    : q(`SELECT * FROM nodes WHERE parent_id IS NULL ORDER BY position, created_at`);

  async function projectOf(id) { let n = await getNode(id); while (n && n.parent_id) n = await getNode(n.parent_id); return n; }

  const descendants = id => q(`WITH RECURSIVE sub(id) AS (
      SELECT id FROM nodes WHERE parent_id=$1
      UNION ALL SELECT n.id FROM nodes n JOIN sub ON n.parent_id=sub.id
    ) SELECT n.* FROM nodes n JOIN sub ON n.id=sub.id ORDER BY n.position, n.created_at`, [id]);

  async function nextPosition(parent_id) {
    const r = parent_id ? await q1(`SELECT COALESCE(MAX(position),-1)+1 AS p FROM nodes WHERE parent_id=$1`, [parent_id])
      : await q1(`SELECT COALESCE(MAX(position),-1)+1 AS p FROM nodes WHERE parent_id IS NULL`);
    return Number(r.p);
  }

  async function createNode(fields, actor = 'human') {
    const id = fields.id || uid();
    const kind = fields.parent_id ? 'task' : 'project';
    if (fields.mode && !MODES.includes(fields.mode)) throw new Error(`invalid mode; use one of ${MODES.join(', ')} or empty`);
    const position = fields.position ?? await nextPosition(fields.parent_id || null);
    await q(`INSERT INTO nodes (id,parent_id,kind,title,goal,success_criteria,constraints,assignee,state,due,position,mode)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`, [
      id, fields.parent_id || null, kind, fields.title || '', fields.goal || '', fields.success_criteria || '',
      fields.constraints || '', fields.assignee || (kind === 'project' ? 'unassigned' : 'human'),
      fields.state || 'todo', fields.due || null, position, fields.mode || '']);
    for (const dep of fields.deps || []) await q(`INSERT INTO deps VALUES ($1,$2) ON CONFLICT DO NOTHING`, [id, dep]);
    await log(id, actor, 'create', fields.title || '');
    return getNode(id);
  }

  const EDITABLE = ['title', 'goal', 'success_criteria', 'constraints', 'assignee', 'state', 'project_status', 'due', 'acceptance_note', 'artifact', 'collapsed', 'mode'];

  async function updateNode(id, patch, actor = 'human', detail = '') {
    const before = await getNode(id);
    if (!before) throw new Error('not found');
    const keys = Object.keys(patch).filter(k => EDITABLE.includes(k));
    if (patch.mode !== undefined && patch.mode !== '' && !MODES.includes(patch.mode)) throw new Error(`invalid mode; use one of ${MODES.join(', ')} or empty`);
    if (keys.length) {
      const sets = keys.map((k, i) => `${k}=$${i + 1}`).join(',');
      await q(`UPDATE nodes SET ${sets}, updated_at=now() WHERE id=$${keys.length + 1}`, [...keys.map(k => patch[k] === undefined ? null : patch[k]), id]);
    }
    if (patch.deps) {
      await q(`DELETE FROM deps WHERE node_id=$1`, [id]);
      for (const dep of patch.deps) if (dep !== id) await q(`INSERT INTO deps VALUES ($1,$2) ON CONFLICT DO NOTHING`, [id, dep]);
    }
    const undo = {}; for (const k of keys) undo[k] = before[k]; if (patch.deps) undo.deps = before.deps;
    const changed = keys.filter(k => String(before[k] ?? '') !== String(patch[k] ?? ''));
    if (changed.length || patch.deps) await log(id, actor, 'update', detail || changed.map(k => `${k}: ${before[k]} → ${patch[k]}`).join('; '), undo);
    return getNode(id);
  }

  async function moveNode(id, parent_id, position, actor = 'human') {
    const n = await getNode(id);
    if (!n) throw new Error('not found');
    if (parent_id === id || (await descendants(id)).some(x => x.id === parent_id)) throw new Error('cannot move into own subtree');
    const siblings = (await children(parent_id)).filter(s => s.id !== id);
    siblings.splice(Math.max(0, Math.min(position, siblings.length)), 0, n);
    const kind = parent_id ? 'task' : 'project';
    const desc = await descendants(id);
    const oldSiblings = (await children(n.parent_id)).filter(s => s.id !== id);
    await d.tx(async t => {
      for (let i = 0; i < siblings.length; i++) await t(`UPDATE nodes SET position=$1 WHERE id=$2`, [i, siblings[i].id]);
      await t(`UPDATE nodes SET parent_id=$1, kind=$2, updated_at=now() WHERE id=$3`, [parent_id, kind, id]);
      for (const x of desc) await t(`UPDATE nodes SET kind='task' WHERE id=$1`, [x.id]);
      if (n.parent_id !== parent_id) for (let i = 0; i < oldSiblings.length; i++) await t(`UPDATE nodes SET position=$1 WHERE id=$2`, [i, oldSiblings[i].id]);
    });
    await log(id, actor, 'move', `→ ${parent_id || 'root'} @${position}`, { parent_id: n.parent_id, position: n.position });
    return getNode(id);
  }

  async function deleteNode(id) {
    const n = await getNode(id); if (!n) return;
    await q(`DELETE FROM nodes WHERE id=$1`, [id]);
    const sib = await children(n.parent_id);
    for (let i = 0; i < sib.length; i++) await q(`UPDATE nodes SET position=$1 WHERE id=$2`, [i, sib[i].id]);
  }

  async function progress(id) {
    const desc = (await descendants(id)).filter(x => x.kind === 'task');
    const ids = new Set(desc.map(x => x.id));
    const parents = new Set(desc.filter(x => ids.has(x.parent_id)).map(x => x.parent_id));
    const leaves = desc.filter(x => !parents.has(x.id));
    const done = leaves.filter(l => l.state === 'done').length;
    return { total: leaves.length, done, pct: leaves.length ? Math.round(100 * done / leaves.length) : 0 };
  }

  async function depsSatisfied(id) {
    const deps = await q(`SELECT n.state FROM deps dd JOIN nodes n ON n.id=dd.depends_on WHERE dd.node_id=$1`, [id]);
    return deps.every(x => x.state === 'done');
  }

  async function tree() {
    const nodes = await q(`SELECT * FROM nodes ORDER BY position, created_at`);
    const deps = await q(`SELECT * FROM deps`);
    const lastAct = await q(`SELECT DISTINCT ON (node_id) node_id, action, detail, actor, id FROM activity ORDER BY node_id, id DESC`);
    const actMap = Object.fromEntries(lastAct.map(a => [a.node_id, a]));
    const byId = Object.fromEntries(nodes.map(n => [n.id, { ...n, deps: [], children: [], last_activity: actMap[n.id] || null }]));
    for (const x of deps) byId[x.node_id]?.deps.push(x.depends_on);
    const roots = [];
    for (const n of nodes) { const node = byId[n.id]; if (n.parent_id && byId[n.parent_id]) byId[n.parent_id].children.push(node); else roots.push(node); }
    const leafStats = node => { if (!node.children.length) return { t: 1, d: node.state === 'done' ? 1 : 0 }; let t = 0, dn = 0; for (const c of node.children) { const s = leafStats(c); t += s.t; dn += s.d; } return { t, d: dn }; };
    for (const r of roots) { let t = 0, dn = 0; for (const c of r.children) { const s = leafStats(c); t += s.t; dn += s.d; } r.progress = { total: t, done: dn, pct: t ? Math.round(100 * dn / t) : 0 }; }
    return roots;
  }

  async function byMode(assignee = null) {
    const rows = await q(`WITH RECURSIVE up(id, root) AS (
        SELECT id, id FROM nodes WHERE parent_id IS NULL
        UNION ALL SELECT n.id, up.root FROM nodes n JOIN up ON n.parent_id=up.id)
      SELECT n.*, p.title AS project_title FROM nodes n JOIN up ON up.id=n.id JOIN nodes p ON p.id=up.root
      WHERE n.kind='task' AND n.state <> 'done' AND p.project_status='active'
        AND NOT EXISTS (SELECT 1 FROM nodes c WHERE c.parent_id=n.id)
        ${assignee ? 'AND n.assignee=$1' : ''}
      ORDER BY n.mode, COALESCE(n.due,'9999'), p.position, n.position`, assignee ? [assignee] : []);
    const groups = {};
    for (const r of rows) (groups[r.mode || 'unsorted'] ||= []).push(r);
    return groups;
  }

  // Inbox
  async function propose(project_id, type, summary, payload = {}, node_id = null) {
    const dup = node_id
      ? await q1(`SELECT id FROM inbox WHERE project_id=$1 AND type=$2 AND node_id=$3 AND summary=$4`, [project_id, type, node_id, summary])
      : await q1(`SELECT id FROM inbox WHERE project_id=$1 AND type=$2 AND node_id IS NULL AND summary=$3`, [project_id, type, summary]);
    if (dup) return dup.id;
    const id = uid();
    await q(`INSERT INTO inbox (id,project_id,node_id,type,summary,payload) VALUES ($1,$2,$3,$4,$5,$6)`, [id, project_id, node_id, type, summary, JSON.stringify(payload)]);
    return id;
  }
  const inbox = (status = 'open') => q(`SELECT * FROM inbox WHERE status=$1 ORDER BY created_at DESC`, [status]).then(rs => rs.map(r => ({ ...r, payload: JSON.parse(r.payload) })));
  const getProposal = id => q1(`SELECT * FROM inbox WHERE id=$1`, [id]).then(r => r && { ...r, payload: JSON.parse(r.payload) });
  const setProposalStatus = (id, status) => q(`UPDATE inbox SET status=$1 WHERE id=$2`, [status, id]);

  async function acceptProposal(id, edits = {}) {
    const p = await getProposal(id);
    if (!p || p.status !== 'open') throw new Error('proposal not open');
    const payload = { ...p.payload, ...edits };
    switch (p.type) {
      case 'new_task': await createNode({ parent_id: payload.parent_id || p.project_id, title: payload.title, assignee: payload.assignee || 'ai', due: payload.due, mode: payload.mode || '' }, 'ai'); break;
      case 'decompose': for (const t of payload.subtasks || []) await createNode({ parent_id: p.node_id, title: t.title, assignee: t.assignee || 'ai' }, 'ai'); break;
      case 'reassign': await updateNode(p.node_id, { assignee: payload.assignee }, 'ai', `reassigned to ${payload.assignee} (proposal accepted)`); break;
      case 'stale': case 'blocked_chain': case 'no_path': break;
      default: throw new Error('unknown proposal type');
    }
    await setProposalStatus(id, 'accepted');
  }

  const activity = (node_id, limit = 50) => q(`SELECT * FROM activity WHERE node_id=$1 ORDER BY id DESC LIMIT $2`, [node_id, limit]);
  const recentActivity = (limit = 100) => q(`SELECT a.*, n.title FROM activity a JOIN nodes n ON n.id=a.node_id ORDER BY a.id DESC LIMIT $1`, [limit]);
  async function undoActivity(activity_id) {
    const a = await q1(`SELECT * FROM activity WHERE id=$1`, [activity_id]);
    if (!a || !a.undo) throw new Error('nothing to undo');
    const undo = JSON.parse(a.undo);
    if (a.action === 'move') return moveNode(a.node_id, undo.parent_id, undo.position, 'human');
    return updateNode(a.node_id, undo, 'human', `undo #${activity_id}`);
  }

  const saveDigest = (project_id, day, body) => q(`INSERT INTO digests (project_id, day, body) VALUES ($1,$2,$3) ON CONFLICT (project_id, day) DO UPDATE SET body=excluded.body, created_at=now()`, [project_id, day, body]);
  const digests = (project_id, limit = 7) => q(`SELECT * FROM digests WHERE project_id=$1 ORDER BY day DESC LIMIT $2`, [project_id, limit]);

  // Settings
  const getSetting = key => q1(`SELECT value FROM settings WHERE key=$1`, [key]).then(r => r ? r.value : null);
  const setSetting = (key, value) => q(`INSERT INTO settings (key,value) VALUES ($1,$2) ON CONFLICT (key) DO UPDATE SET value=excluded.value`, [key, value]);
  async function feedToken() { let t = await getSetting('feed_token'); if (!t) { t = crypto.randomBytes(16).toString('hex'); await setSetting('feed_token', t); } return t; }

  // Calendars
  async function addCalendar({ name, kind = 'ics', url = '', project_id = null }) {
    const id = uid();
    await q(`INSERT INTO calendars (id,name,kind,url,project_id) VALUES ($1,$2,$3,$4,$5)`, [id, name, kind, url, project_id]);
    return getCalendar(id);
  }
  const getCalendar = id => q1(`SELECT * FROM calendars WHERE id=$1`, [id]);
  const calendars = () => q(`SELECT c.*, (SELECT COUNT(*)::int FROM events e WHERE e.calendar_id=c.id) AS event_count FROM calendars c ORDER BY created_at`);
  async function updateCalendar(id, patch) {
    const keys = Object.keys(patch).filter(k => ['name', 'kind', 'url', 'project_id', 'enabled', 'last_synced_at', 'last_error'].includes(k));
    if (keys.length) await q(`UPDATE calendars SET ${keys.map((k, i) => `${k}=$${i + 1}`).join(',')} WHERE id=$${keys.length + 1}`, [...keys.map(k => patch[k]), id]);
    return getCalendar(id);
  }
  const deleteCalendar = id => q(`DELETE FROM calendars WHERE id=$1`, [id]);
  const replaceEvents = (calendar_id, evs) => d.tx(async t => {
    await t(`DELETE FROM events WHERE calendar_id=$1`, [calendar_id]);
    for (const e of evs) await t(`INSERT INTO events (calendar_id,uid,title,start,"end",all_day,description,location,url,recurring,status) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT (calendar_id, uid) DO UPDATE SET title=excluded.title, start=excluded.start, "end"=excluded."end"`,
      [calendar_id, e.uid, e.title, e.start, e.end, e.all_day ? 1 : 0, e.description || '', e.location || '', e.url || '', e.recurring ? 1 : 0, e.status || '']);
    await t(`UPDATE calendars SET last_synced_at=now(), last_error=NULL WHERE id=$1`, [calendar_id]);
  });
  function events({ from, to, project_id = null } = {}) {
    const f = from || new Date().toISOString().slice(0, 10);
    const t = to || new Date(Date.now() + 14 * 86400e3).toISOString().slice(0, 10);
    return q(`SELECT e.*, c.name AS calendar_name, c.project_id FROM events e JOIN calendars c ON c.id=e.calendar_id
      WHERE c.enabled=1 AND e."end" >= $1 AND e.start < $2 ${project_id ? 'AND (c.project_id IS NULL OR c.project_id=$3)' : ''}
      ORDER BY e.start`, project_id ? [f, t, project_id] : [f, t]);
  }
  async function dueTasks() {
    const rows = await q(`WITH RECURSIVE up(id, root) AS (SELECT id, id FROM nodes WHERE parent_id IS NULL UNION ALL SELECT n.id, up.root FROM nodes n JOIN up ON n.parent_id=up.id)
      SELECT n.*, row_to_json(p) AS project FROM nodes n JOIN up ON up.id=n.id JOIN nodes p ON p.id=up.root WHERE n.kind='task' AND n.due IS NOT NULL ORDER BY n.due`);
    return rows.map(r => ({ ...r, project: norm(r.project) }));
  }

  // Workspace files (per project)
  const fileList = project_id => q(`SELECT path, length(content) AS bytes FROM files WHERE project_id=$1 ORDER BY path`, [project_id]).then(rs => rs.map(r => ({ path: r.path, bytes: Number(r.bytes) })));
  const fileRead = (project_id, path) => q1(`SELECT content FROM files WHERE project_id=$1 AND path=$2`, [project_id, path]).then(r => r ? r.content : null);
  const fileWrite = (project_id, path, content) => q(`INSERT INTO files (project_id, path, content) VALUES ($1,$2,$3) ON CONFLICT (project_id, path) DO UPDATE SET content=excluded.content, updated_at=now()`, [project_id, path, content]);

  const startRun = project_id => q1(`INSERT INTO harness_runs (project_id) VALUES ($1) RETURNING id`, [project_id]).then(r => r.id);
  const finishRun = (id, status, logText) => q(`UPDATE harness_runs SET finished_at=now(), status=$1, log=$2 WHERE id=$3`, [status, logText, id]);
  const runs = (limit = 20) => q(`SELECT r.*, n.title FROM harness_runs r LEFT JOIN nodes n ON n.id=r.project_id ORDER BY r.id DESC LIMIT $1`, [limit]);

  return {
    raw: d, log, getNode, children, projectOf, descendants, createNode, updateNode, moveNode, deleteNode,
    progress, depsSatisfied, tree, byMode, MODES, propose, inbox, getProposal, setProposalStatus, acceptProposal,
    activity, recentActivity, undoActivity, saveDigest, digests, startRun, finishRun, runs,
    getSetting, setSetting, feedToken, addCalendar, getCalendar, calendars, updateCalendar, deleteCalendar, replaceEvents, events, dueTasks,
    fileList, fileRead, fileWrite,
    close: () => d.close(),
  };
}

module.exports = { open, MODES };
