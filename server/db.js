// Data layer: one `nodes` table holds projects (depth 0) and tasks (nested).
const { DatabaseSync } = require('node:sqlite');
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
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  last_activity_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id, position);

CREATE TABLE IF NOT EXISTS deps (
  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  depends_on TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  PRIMARY KEY (node_id, depends_on)
);

CREATE TABLE IF NOT EXISTS activity (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  node_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  actor TEXT NOT NULL CHECK (actor IN ('human','ai','harness')),
  action TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  undo TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
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
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS digests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  UNIQUE(project_id, day)
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS calendars (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'ics',
  url TEXT NOT NULL DEFAULT '',
  project_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_synced_at TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS events (
  calendar_id TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE,
  uid TEXT NOT NULL,
  title TEXT NOT NULL,
  start TEXT NOT NULL,
  end TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0,
  description TEXT NOT NULL DEFAULT '',
  location TEXT NOT NULL DEFAULT '',
  url TEXT NOT NULL DEFAULT '',
  recurring INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (calendar_id, uid)
);
CREATE INDEX IF NOT EXISTS idx_events_start ON events(start);

CREATE TABLE IF NOT EXISTS harness_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  finished_at TEXT,
  status TEXT NOT NULL DEFAULT 'running',
  log TEXT NOT NULL DEFAULT ''
);
`;

const now = () => new Date().toISOString();
const uid = () => crypto.randomUUID();

function open(path = process.env.DB_PATH || 'schrodinger.db') {
  const db = new DatabaseSync(path);
  db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 10000;');
  db.exec(SCHEMA);
  migrate(db);
  return wrap(db);
}

const MODES = ['call','errand','email','write','research','meeting','admin','other'];

function migrate(db) {
  const cols = db.prepare(`PRAGMA table_info(nodes)`).all().map(c => c.name);
  if (!cols.includes('mode')) db.exec(`ALTER TABLE nodes ADD COLUMN mode TEXT NOT NULL DEFAULT ''`);
}

function wrap(db) {
  const q = (sql) => db.prepare(sql);

  function log(node_id, actor, action, detail = '', undo = null) {
    q(`INSERT INTO activity (node_id, actor, action, detail, undo) VALUES (?,?,?,?,?)`)
      .run(node_id, actor, action, detail, undo ? JSON.stringify(undo) : null);
    q(`UPDATE nodes SET last_activity_at=? WHERE id=?`).run(now(), node_id);
  }

  function getNode(id) {
    const n = q(`SELECT * FROM nodes WHERE id=?`).get(id);
    if (!n) return null;
    n.deps = q(`SELECT depends_on FROM deps WHERE node_id=?`).all(id).map(r => r.depends_on);
    return n;
  }

  function children(parent_id) {
    return q(`SELECT * FROM nodes WHERE parent_id IS ? ORDER BY position, created_at`).all(parent_id);
  }

  function projectOf(id) {
    let n = getNode(id);
    while (n && n.parent_id) n = getNode(n.parent_id);
    return n;
  }

  function descendants(id) {
    return q(`WITH RECURSIVE sub(id) AS (
      SELECT id FROM nodes WHERE parent_id=?
      UNION ALL SELECT n.id FROM nodes n JOIN sub ON n.parent_id=sub.id
    ) SELECT n.* FROM nodes n JOIN sub ON n.id=sub.id`).all(id);
  }

  function nextPosition(parent_id) {
    const r = q(`SELECT COALESCE(MAX(position),-1)+1 AS p FROM nodes WHERE parent_id IS ?`).get(parent_id);
    return r.p;
  }

  function createNode(fields, actor = 'human') {
    const id = fields.id || uid();
    const kind = fields.parent_id ? 'task' : 'project';
    const position = fields.position ?? nextPosition(fields.parent_id || null);
    q(`INSERT INTO nodes (id,parent_id,kind,title,goal,success_criteria,constraints,assignee,state,due,position,mode)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(
      id, fields.parent_id || null, kind, fields.title || '', fields.goal || '', fields.success_criteria || '',
      fields.constraints || '', fields.assignee || (kind === 'project' ? 'unassigned' : 'human'),
      fields.state || 'todo', fields.due || null, position, fields.mode || '');
    for (const d of fields.deps || []) q(`INSERT OR IGNORE INTO deps VALUES (?,?)`).run(id, d);
    log(id, actor, 'create', fields.title || '');
    return getNode(id);
  }

  const EDITABLE = ['title','goal','success_criteria','constraints','assignee','state','project_status','due','acceptance_note','artifact','collapsed','mode'];

  function updateNode(id, patch, actor = 'human', detail = '') {
    const before = getNode(id);
    if (!before) throw new Error('not found');
    const keys = Object.keys(patch).filter(k => EDITABLE.includes(k));
    if (patch.mode !== undefined && patch.mode !== '' && !MODES.includes(patch.mode)) throw new Error(`invalid mode; use one of ${MODES.join(', ')} or empty`);
    if (keys.length) {
      const sets = keys.map(k => `${k}=?`).join(',');
      q(`UPDATE nodes SET ${sets}, updated_at=? WHERE id=?`).run(...keys.map(k => patch[k]), now(), id);
    }
    if (patch.deps) {
      q(`DELETE FROM deps WHERE node_id=?`).run(id);
      for (const d of patch.deps) if (d !== id) q(`INSERT OR IGNORE INTO deps VALUES (?,?)`).run(id, d);
    }
    const undo = {};
    for (const k of keys) undo[k] = before[k];
    if (patch.deps) undo.deps = before.deps;
    const changed = keys.filter(k => before[k] !== patch[k]);
    if (changed.length || patch.deps) log(id, actor, 'update', detail || changed.map(k => `${k}: ${before[k]} → ${patch[k]}`).join('; '), undo);
    return getNode(id);
  }

  function moveNode(id, parent_id, position, actor = 'human') {
    const n = getNode(id);
    if (!n) throw new Error('not found');
    if (parent_id === id || descendants(id).some(d => d.id === parent_id)) throw new Error('cannot move into own subtree');
    const siblings = children(parent_id).filter(s => s.id !== id);
    siblings.splice(Math.max(0, Math.min(position, siblings.length)), 0, n);
    const kind = parent_id ? 'task' : 'project';
    db.exec('BEGIN');
    try {
      siblings.forEach((s, i) => q(`UPDATE nodes SET position=? WHERE id=?`).run(i, s.id));
      q(`UPDATE nodes SET parent_id=?, kind=?, updated_at=? WHERE id=?`).run(parent_id, kind, now(), id);
      // re-kind descendants (all tasks)
      for (const d of descendants(id)) q(`UPDATE nodes SET kind='task' WHERE id=?`).run(d.id);
      // cascade position fix on old parent
      children(n.parent_id).forEach((s, i) => q(`UPDATE nodes SET position=? WHERE id=?`).run(i, s.id));
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    log(id, actor, 'move', `→ ${parent_id || 'root'} @${position}`, { parent_id: n.parent_id, position: n.position });
    return getNode(id);
  }

  function deleteNode(id, actor = 'human') {
    const n = getNode(id);
    if (!n) return;
    q(`DELETE FROM nodes WHERE id=?`).run(id);
    children(n.parent_id).forEach((s, i) => q(`UPDATE nodes SET position=? WHERE id=?`).run(i, s.id));
  }

  // Leaf tasks under a node; progress = done leaves / leaves.
  function progress(id) {
    const desc = descendants(id).filter(d => d.kind === 'task');
    const ids = new Set(desc.map(d => d.id));
    const parents = new Set(desc.filter(d => ids.has(d.parent_id)).map(d => d.parent_id));
    const leaves = desc.filter(d => !parents.has(d.id));
    const done = leaves.filter(l => l.state === 'done').length;
    return { total: leaves.length, done, pct: leaves.length ? Math.round(100 * done / leaves.length) : 0 };
  }

  function depsSatisfied(id) {
    const deps = q(`SELECT d.depends_on, n.state FROM deps d JOIN nodes n ON n.id=d.depends_on WHERE d.node_id=?`).all(id);
    return deps.every(d => d.state === 'done');
  }

  // Full tree for the UI.
  function tree() {
    const all = q(`SELECT * FROM nodes ORDER BY position, created_at`).all();
    const deps = q(`SELECT * FROM deps`).all();
    const lastAct = q(`SELECT node_id, action, detail, actor, MAX(id) AS id FROM activity GROUP BY node_id`).all();
    const actMap = Object.fromEntries(lastAct.map(a => [a.node_id, a]));
    const byId = Object.fromEntries(all.map(n => [n.id, { ...n, deps: [], children: [], last_activity: actMap[n.id] || null }]));
    for (const d of deps) byId[d.node_id]?.deps.push(d.depends_on);
    const roots = [];
    for (const n of all) {
      const node = byId[n.id];
      if (n.parent_id && byId[n.parent_id]) byId[n.parent_id].children.push(node); else roots.push(node);
    }
    for (const r of roots) r.progress = progress(r.id);
    return roots;
  }

  // Open leaf tasks grouped by mode, across projects (for batching work).
  function byMode(assignee = null) {
    const rows = q(`SELECT n.*, p.title AS project_title FROM nodes n
      JOIN nodes p ON p.id = (WITH RECURSIVE up(id,parent_id) AS (SELECT id,parent_id FROM nodes WHERE id=n.id UNION ALL SELECT x.id,x.parent_id FROM nodes x JOIN up ON x.id=up.parent_id) SELECT id FROM up WHERE parent_id IS NULL)
      WHERE n.kind='task' AND n.state NOT IN ('done') AND p.project_status='active'
        AND NOT EXISTS (SELECT 1 FROM nodes c WHERE c.parent_id=n.id)
        ${assignee ? 'AND n.assignee=?' : ''}
      ORDER BY n.mode, COALESCE(n.due,'9999'), p.position, n.position`).all(...(assignee ? [assignee] : []));
    const groups = {};
    for (const r of rows) (groups[r.mode || 'unsorted'] ||= []).push(r);
    return groups;
  }

  // Inbox
  function propose(project_id, type, summary, payload = {}, node_id = null) {
    // dedupe: identical proposal already open, or previously accepted/dismissed by the human → do not re-raise
    const dup = q(`SELECT id FROM inbox WHERE project_id=? AND type=? AND node_id IS ? AND summary=?`).get(project_id, type, node_id, summary);
    if (dup) return dup.id;
    const id = uid();
    q(`INSERT INTO inbox (id,project_id,node_id,type,summary,payload) VALUES (?,?,?,?,?,?)`)
      .run(id, project_id, node_id, type, summary, JSON.stringify(payload));
    return id;
  }
  function inbox(status = 'open') {
    return q(`SELECT * FROM inbox WHERE status=? ORDER BY created_at DESC`).all(status).map(r => ({ ...r, payload: JSON.parse(r.payload) }));
  }
  function getProposal(id) { const r = q(`SELECT * FROM inbox WHERE id=?`).get(id); return r && { ...r, payload: JSON.parse(r.payload) }; }
  function setProposalStatus(id, status) { q(`UPDATE inbox SET status=? WHERE id=?`).run(status, id); }

  // Apply a proposal (human clicked accept). Structural changes happen only here.
  function acceptProposal(id, edits = {}) {
    const p = getProposal(id);
    if (!p || p.status !== 'open') throw new Error('proposal not open');
    const payload = { ...p.payload, ...edits };
    switch (p.type) {
      case 'new_task':
        createNode({ parent_id: payload.parent_id || p.project_id, title: payload.title, assignee: payload.assignee || 'ai', due: payload.due, mode: payload.mode || '' }, 'ai');
        break;
      case 'decompose':
        for (const t of payload.subtasks || []) createNode({ parent_id: p.node_id, title: t.title, assignee: t.assignee || 'ai' }, 'ai');
        break;
      case 'reassign':
        updateNode(p.node_id, { assignee: payload.assignee }, 'ai', `reassigned to ${payload.assignee} (proposal accepted)`);
        break;
      case 'stale':
      case 'blocked_chain':
      case 'no_path':
        // informational; accepting just acknowledges
        break;
      default: throw new Error('unknown proposal type');
    }
    setProposalStatus(id, 'accepted');
  }

  function activity(node_id, limit = 50) {
    return q(`SELECT * FROM activity WHERE node_id=? ORDER BY id DESC LIMIT ?`).all(node_id, limit);
  }
  function recentActivity(limit = 100) {
    return q(`SELECT a.*, n.title FROM activity a JOIN nodes n ON n.id=a.node_id ORDER BY a.id DESC LIMIT ?`).all(limit);
  }
  function undoActivity(activity_id) {
    const a = q(`SELECT * FROM activity WHERE id=?`).get(activity_id);
    if (!a || !a.undo) throw new Error('nothing to undo');
    const undo = JSON.parse(a.undo);
    if (a.action === 'move') return moveNode(a.node_id, undo.parent_id, undo.position, 'human');
    return updateNode(a.node_id, undo, 'human', `undo #${activity_id}`);
  }

  function saveDigest(project_id, day, body) {
    q(`INSERT INTO digests (project_id, day, body) VALUES (?,?,?) ON CONFLICT(project_id, day) DO UPDATE SET body=excluded.body, created_at=excluded.created_at`).run(project_id, day, body);
  }
  function digests(project_id, limit = 7) {
    return q(`SELECT * FROM digests WHERE project_id=? ORDER BY day DESC LIMIT ?`).all(project_id, limit);
  }

  // Settings
  function getSetting(key) { const r = q(`SELECT value FROM settings WHERE key=?`).get(key); return r ? r.value : null; }
  function setSetting(key, value) { q(`INSERT INTO settings (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`).run(key, value); }
  function feedToken() { let t = getSetting('feed_token'); if (!t) { t = crypto.randomBytes(16).toString('hex'); setSetting('feed_token', t); } return t; }

  // Calendars
  function addCalendar({ name, kind = 'ics', url = '', project_id = null }) {
    const id = uid();
    q(`INSERT INTO calendars (id,name,kind,url,project_id) VALUES (?,?,?,?,?)`).run(id, name, kind, url, project_id);
    return getCalendar(id);
  }
  function getCalendar(id) { return q(`SELECT * FROM calendars WHERE id=?`).get(id); }
  function calendars() { return q(`SELECT c.*, (SELECT COUNT(*) FROM events e WHERE e.calendar_id=c.id) AS event_count FROM calendars c ORDER BY created_at`).all(); }
  function updateCalendar(id, patch) {
    const keys = Object.keys(patch).filter(k => ['name','kind','url','project_id','enabled','last_synced_at','last_error'].includes(k));
    if (keys.length) q(`UPDATE calendars SET ${keys.map(k => `${k}=?`).join(',')} WHERE id=?`).run(...keys.map(k => patch[k]), id);
    return getCalendar(id);
  }
  function deleteCalendar(id) { q(`DELETE FROM calendars WHERE id=?`).run(id); }
  function replaceEvents(calendar_id, evs) {
    db.exec('BEGIN');
    try {
      q(`DELETE FROM events WHERE calendar_id=?`).run(calendar_id);
      const ins = q(`INSERT OR REPLACE INTO events (calendar_id,uid,title,start,end,all_day,description,location,url,recurring,status) VALUES (?,?,?,?,?,?,?,?,?,?,?)`);
      for (const e of evs) ins.run(calendar_id, e.uid, e.title, e.start, e.end, e.all_day ? 1 : 0, e.description || '', e.location || '', e.url || '', e.recurring ? 1 : 0, e.status || '');
      q(`UPDATE calendars SET last_synced_at=?, last_error=NULL WHERE id=?`).run(now(), calendar_id);
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
  }
  // Events in [from, to) — ISO strings; all-day dates compare lexically with ISO datetimes correctly enough for day granularity.
  function events({ from, to, project_id = null } = {}) {
    const f = from || new Date().toISOString().slice(0, 10);
    const t = to || new Date(Date.now() + 14 * 86400e3).toISOString().slice(0, 10);
    return q(`SELECT e.*, c.name AS calendar_name, c.project_id FROM events e JOIN calendars c ON c.id=e.calendar_id
      WHERE c.enabled=1 AND e.end >= ? AND e.start < ? ${project_id ? 'AND (c.project_id IS NULL OR c.project_id=?)' : ''}
      ORDER BY e.start`).all(f, t, ...(project_id ? [project_id] : []));
  }
  // Tasks with due dates (for the outbound feed)
  function dueTasks() {
    return q(`SELECT n.* FROM nodes n WHERE n.kind='task' AND n.due IS NOT NULL ORDER BY n.due`).all().map(t => ({ ...t, project: projectOf(t.id) }));
  }

  function startRun(project_id) { return q(`INSERT INTO harness_runs (project_id) VALUES (?)`).run(project_id).lastInsertRowid; }
  function finishRun(id, status, logText) { q(`UPDATE harness_runs SET finished_at=?, status=?, log=? WHERE id=?`).run(now(), status, logText, id); }
  function runs(limit = 20) { return q(`SELECT r.*, n.title FROM harness_runs r LEFT JOIN nodes n ON n.id=r.project_id ORDER BY r.id DESC LIMIT ?`).all(limit); }

  return {
    raw: db, log, getNode, children, projectOf, descendants, createNode, updateNode, moveNode, deleteNode,
    progress, depsSatisfied, tree, byMode, MODES, propose, inbox, getProposal, setProposalStatus, acceptProposal,
    activity, recentActivity, undoActivity, saveDigest, digests, startRun, finishRun, runs,
    getSetting, setSetting, feedToken, addCalendar, getCalendar, calendars, updateCalendar, deleteCalendar, replaceEvents, events, dueTasks,
    close: () => db.close(),
  };
}

module.exports = { open };
