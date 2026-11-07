const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const { open } = require('../server/db');
const { createHarness } = require('../harness');
const { createApp } = require('../server/app');

process.env.HARNESS_MOCK = '1';
process.env.WORKSPACE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-root-'));

function tmpDb() {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'ht-')), 't.db');
  return { path: p, db: open(p) };
}

test('tree: create, nest, move, progress, cannot move into own subtree', () => {
  const { db } = tmpDb();
  const p = db.createNode({ title: 'P', goal: 'g' });
  const a = db.createNode({ parent_id: p.id, title: 'A' });
  const b = db.createNode({ parent_id: p.id, title: 'B' });
  const a1 = db.createNode({ parent_id: a.id, title: 'A1' });
  assert.equal(p.kind, 'project'); assert.equal(a.kind, 'task');
  assert.deepEqual(db.progress(p.id), { total: 2, done: 0, pct: 0 }); // leaves: A1, B
  db.updateNode(a1.id, { state: 'done' });
  assert.equal(db.progress(p.id).pct, 50);
  db.moveNode(b.id, a.id, 0);
  assert.deepEqual(db.children(a.id).map(c => c.title), ['B', 'A1']);
  assert.throws(() => db.moveNode(a.id, a1.id, 0), /own subtree/);
  const t = db.tree();
  assert.equal(t[0].children.length, 1); assert.equal(t[0].children[0].children.length, 2);
});

test('deps gate AI pickup; review → approve/reject flow; rejection note feeds redraft', async () => {
  const { db, path: dbPath } = tmpDb();
  const p = db.createNode({ title: 'P', goal: 'ship' });
  const t1 = db.createNode({ parent_id: p.id, title: 'first', assignee: 'ai' });
  const t2 = db.createNode({ parent_id: p.id, title: 'second', assignee: 'ai', deps: [t1.id] });
  const h = db.createNode({ parent_id: p.id, title: 'human thing', assignee: 'human' });
  const harness = createHarness(db, { dbPath, inProcess: true });

  await harness.runOnce();
  assert.equal(db.getNode(t1.id).state, 'review');
  assert.ok(db.getNode(t1.id).artifact.includes('Draft: first'));
  assert.equal(db.getNode(t2.id).state, 'todo', 'dependent task not picked up');
  assert.equal(db.getNode(h.id).state, 'todo', 'human task untouched');

  // reject with note → back to todo, redraft includes note
  db.updateNode(t1.id, { state: 'todo', acceptance_note: 'make it shorter' }, 'human', 'rejected');
  await harness.runOnce();
  assert.equal(db.getNode(t1.id).state, 'review');
  assert.ok(db.getNode(t1.id).artifact.includes('make it shorter'));

  // approve → done unlocks t2
  db.updateNode(t1.id, { state: 'done' }, 'human', 'approved');
  await harness.runOnce();
  assert.equal(db.getNode(t2.id).state, 'review');
  assert.equal(db.progress(p.id).done, 1);
});

test('harness spawns one sub-agent process per active project; paused projects skipped', async () => {
  const { db, path: dbPath } = tmpDb();
  const p1 = db.createNode({ title: 'P1' }); db.createNode({ parent_id: p1.id, title: 'x', assignee: 'ai' });
  const p2 = db.createNode({ title: 'P2' }); db.createNode({ parent_id: p2.id, title: 'y', assignee: 'ai' });
  const p3 = db.createNode({ title: 'P3', project_status: 'paused' }); db.updateNode(p3.id, { project_status: 'paused' });
  const z = db.createNode({ parent_id: p3.id, title: 'z', assignee: 'ai' });
  const harness = createHarness(db, { dbPath }); // real child processes
  const r = await harness.runOnce();
  assert.equal(r.ran, 2);
  assert.ok(r.results.every(x => x.code === 0), JSON.stringify(r.results));
  assert.equal(db.getNode(z.id).state, 'todo');
  assert.equal(db.runs().filter(x => x.status === 'ok').length, 2);
});

test('proposals: structural changes only land in inbox; accept applies, dismiss does not', async () => {
  const { db, path: dbPath } = tmpDb();
  const p = db.createNode({ title: 'Grant', goal: 'submit' });
  const big = db.createNode({ parent_id: p.id, title: 'Research rules and draft budget', assignee: 'ai' });
  const empty = db.createNode({ title: 'Empty' });
  const harness = createHarness(db, { dbPath, inProcess: true });
  await harness.runOnce();
  const inbox = db.inbox();
  const dec = inbox.find(i => i.type === 'decompose' && i.node_id === big.id);
  const nt = inbox.find(i => i.type === 'new_task' && i.project_id === empty.id);
  assert.ok(dec && nt);
  assert.equal(db.children(big.id).length, 0, 'no subtasks created without approval');
  assert.equal(db.children(empty.id).length, 0);

  db.acceptProposal(dec.id);
  assert.deepEqual(db.children(big.id).map(c => c.title), ['Research rules', 'draft budget']);
  db.setProposalStatus(nt.id, 'dismissed');
  assert.equal(db.children(empty.id).length, 0);
  assert.equal(db.inbox().length, 0);

  // idempotent: second run does not duplicate open proposals
  await harness.runOnce();
  const again = db.inbox();
  assert.equal(again.filter(i => i.type === 'new_task' && i.project_id === empty.id).length, 0, 'dismissed not re-raised while... ');
});

test('stale + blocked-chain detection and digest content', async () => {
  const { db, path: dbPath } = tmpDb();
  process.env.STALE_DAYS = '1';
  const p = db.createNode({ title: 'P', goal: 'g' });
  const blocked = db.createNode({ parent_id: p.id, title: 'blocked one', assignee: 'human', state: 'blocked' });
  const dep = db.createNode({ parent_id: p.id, title: 'after blocked', assignee: 'ai', deps: [blocked.id] });
  const old = db.createNode({ parent_id: p.id, title: 'old task', assignee: 'human' });
  db.raw.prepare(`UPDATE nodes SET last_activity_at=? WHERE id=?`).run(new Date(Date.now() - 3 * 86400e3).toISOString(), old.id);
  const harness = createHarness(db, { dbPath, inProcess: true });
  await harness.runOnce();
  const types = db.inbox().map(i => i.type);
  assert.ok(types.includes('blocked_chain'));
  assert.ok(types.includes('stale'));
  assert.equal(db.getNode(dep.id).state, 'todo', 'AI task behind blocked dep not executed');
  const d = db.digests(p.id)[0];
  assert.ok(d.body.includes('## Blocked') && d.body.includes('blocked one'));
  assert.ok(d.body.includes('AI waiting on your task before: after blocked'));
  delete process.env.STALE_DAYS;
});

test('undo reverses AI state change from activity log', () => {
  const { db } = tmpDb();
  const p = db.createNode({ title: 'P' });
  const t = db.createNode({ parent_id: p.id, title: 't', assignee: 'ai' });
  db.updateNode(t.id, { state: 'review', artifact: 'x' }, 'ai', 'draft');
  const act = db.activity(t.id)[0];
  db.undoActivity(act.id);
  const n = db.getNode(t.id);
  assert.equal(n.state, 'todo'); assert.equal(n.artifact, null);
});

test('HTTP API: create, patch, approve/reject guards, inbox accept', async () => {
  const { db, path: dbPath } = tmpDb();
  const harness = createHarness(db, { dbPath, inProcess: true });
  const app = createApp(db, harness);
  const server = await new Promise(res => { const s = app.listen(0, () => res(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = (m, u, b) => new Promise((res, rej) => {
    const req = http.request(base + u, { method: m, headers: { 'content-type': 'application/json' } }, r => {
      let d = ''; r.on('data', c => d += c); r.on('end', () => res({ status: r.statusCode, body: d ? JSON.parse(d) : null }));
    });
    req.on('error', rej); if (b) req.write(JSON.stringify(b)); req.end();
  });
  try {
    const p = (await call('POST', '/api/nodes', { title: 'P', goal: 'g' })).body;
    const t = (await call('POST', '/api/nodes', { parent_id: p.id, title: 'draft memo', assignee: 'ai' })).body;
    assert.equal((await call('POST', `/api/nodes/${t.id}/approve`)).status, 400, 'cannot approve non-review task');
    const run = await call('POST', '/api/harness/run', { project_id: p.id });
    assert.equal(run.body.ran, 1);
    const tree = (await call('GET', '/api/tree')).body;
    assert.equal(tree[0].children[0].state, 'review');
    const rej = await call('POST', `/api/nodes/${t.id}/reject`, { note: 'tighten' });
    assert.equal(rej.body.state, 'todo'); assert.ok(rej.body.acceptance_note.includes('tighten'));
    const mv = await call('POST', `/api/nodes/${t.id}/move`, { parent_id: t.id, position: 0 });
    assert.equal(mv.status, 400);
    const digests = (await call('GET', `/api/nodes/${p.id}/digests`)).body;
    assert.equal(digests.length, 1);
  } finally { server.close(); }
});

test('mode: set, validate, migrate, batch across projects', async () => {
  const { db, path: dbPath } = tmpDb();
  const p1 = db.createNode({ title: 'P1' }); const p2 = db.createNode({ title: 'P2' });
  const c1 = db.createNode({ parent_id: p1.id, title: 'call a', mode: 'call', due: '2030-01-02' });
  const c2 = db.createNode({ parent_id: p2.id, title: 'call b', mode: 'call', due: '2030-01-01' });
  const e1 = db.createNode({ parent_id: p2.id, title: 'buy stamps', mode: 'errand' });
  const u = db.createNode({ parent_id: p1.id, title: 'no mode' });
  const parentTask = db.createNode({ parent_id: p1.id, title: 'parent', mode: 'call' });
  db.createNode({ parent_id: parentTask.id, title: 'child call', mode: 'call' });
  assert.throws(() => db.updateNode(u.id, { mode: 'bogus' }), /invalid mode/);
  db.updateNode(u.id, { mode: 'email' });
  const g = db.byMode();
  assert.deepEqual(g.call.map(t => t.title), ['call b', 'call a', 'child call'], 'sorted by due, parents excluded');
  assert.equal(g.call[0].project_title, 'P2');
  assert.deepEqual(Object.keys(g).sort(), ['call', 'email', 'errand']);
  db.updateNode(c2.id, { state: 'done' });
  assert.equal(db.byMode().call.length, 2, 'done excluded');
  assert.equal(db.byMode('ai').call, undefined, 'assignee filter');
  // migration: old DB without mode column gets it added
  const { DatabaseSync } = require('node:sqlite');
  const oldPath = dbPath + '.old';
  const raw = new DatabaseSync(oldPath);
  raw.exec(`CREATE TABLE nodes (id TEXT PRIMARY KEY, parent_id TEXT, kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', goal TEXT NOT NULL DEFAULT '', success_criteria TEXT NOT NULL DEFAULT '', constraints TEXT NOT NULL DEFAULT '', assignee TEXT NOT NULL DEFAULT 'unassigned', state TEXT NOT NULL DEFAULT 'todo', project_status TEXT NOT NULL DEFAULT 'active', due TEXT, acceptance_note TEXT NOT NULL DEFAULT '', artifact TEXT, position INTEGER NOT NULL DEFAULT 0, collapsed INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '', last_activity_at TEXT NOT NULL DEFAULT '')`);
  raw.exec(`INSERT INTO nodes (id, kind, title) VALUES ('old', 'project', 'Old')`);
  raw.close();
  const migrated = open(oldPath);
  assert.equal(migrated.getNode('old').mode, '');
  migrated.close();
});

test('tools: workspace jail, write/read/list, no send-type tools, context', async () => {
  const { db } = tmpDb();
  process.env.WORKSPACE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-'));
  const { makeTools } = require('../harness/tools');
  const p = db.createNode({ title: 'P', goal: 'g', constraints: 'draft only' });
  const t = db.createNode({ parent_id: p.id, title: 't', assignee: 'ai', mode: 'write' });
  const tools = makeTools({ db, project: p, task: t });
  const names = tools.defs.map(d => d.name);
  assert.ok(!names.some(n => /send|post|commit|email|publish/.test(n)), 'no external-action tools');
  await tools.call('write_file', { path: 'a/b.md', content: 'hi' });
  assert.equal((await tools.call('read_file', { path: 'a/b.md' })).content, 'hi');
  assert.deepEqual((await tools.call('list_files', {})).files.map(f => f.path), ['a/b.md']);
  await assert.rejects(tools.call('read_file', { path: '../../etc/passwd' }), /escapes/);
  await assert.rejects(tools.call('write_file', { path: '/tmp/x', content: '' }), /escapes/);
  await assert.rejects(tools.call('web_fetch', { url: 'file:///etc/passwd' }), /http/);
  const ctx = await tools.call('project_context', {});
  assert.equal(ctx.project.constraints, 'draft only'); assert.equal(ctx.tasks[0].mode, 'write');
  assert.ok(fs.existsSync(path.join(process.env.WORKSPACE_DIR, p.id, 'a', 'b.md')));
});

test('agent loop: scripted model runs tools then finish; turn limit; tool errors fed back', async () => {
  const { db } = tmpDb();
  process.env.WORKSPACE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-'));
  const llm = require('../harness/llm');
  const p = db.createNode({ title: 'P', goal: 'g' });
  const t = db.createNode({ parent_id: p.id, title: 'write memo', assignee: 'ai' });
  const r = await llm.draft({ db, project: p, task: t, siblings: [], rejectionNotes: '' });
  assert.ok(r.artifact.startsWith('# Draft: write memo'));
  assert.ok(r.artifact.includes('Needs from you'));
  assert.deepEqual(r.log.map(l => l.split('(')[0]), ['project_context', 'write_file', 'finish']);

  // model that keeps calling an unknown tool → error result fed back, then hits turn limit
  process.env.AGENT_MAX_TURNS = '3';
  let seenError = false;
  const bad = async (messages) => {
    const last = messages[messages.length - 1];
    if (Array.isArray(last.content) && last.content.some(c => c.type === 'tool_result' && c.is_error)) seenError = true;
    return { stop_reason: 'tool_use', content: [{ type: 'tool_use', id: 'x', name: 'nope', input: {} }] };
  };
  delete require.cache[require.resolve('../harness/llm')];
  const llm2 = require('../harness/llm');
  const r2 = await llm2.draft({ db, project: p, task: t, siblings: [], rejectionNotes: '', model: bad });
  assert.ok(seenError); assert.ok(r2.artifact.includes('turn limit'));
  delete process.env.AGENT_MAX_TURNS;
});

const SAMPLE_ICS = (d1, d2) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\nBEGIN:VEVENT\r\nUID:ev1@test\r\nDTSTART:${d1}T180000Z\r\nDTEND:${d1}T190000Z\r\nSUMMARY:Budget hearing\\, room 2\r\nLOCATION:Capitol\r\nDESCRIPTION:Line one\\nLine two with a very long description that will need to be folded across\r\n multiple lines per RFC 5545 line folding rules\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:ev2@test\r\nDTSTART;VALUE=DATE:${d2}\r\nSUMMARY:Site visit\r\nRRULE:FREQ=WEEKLY\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:ev3@test\r\nDTSTART:20200101T100000Z\r\nDURATION:PT30M\r\nSUMMARY:Old thing\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;
const ymd = d => d.toISOString().slice(0, 10);
const compact = d => ymd(d).replace(/-/g, '');

test('calendar: ICS parse (folding, escapes, all-day, duration, rrule) and task feed generation', () => {
  const cal = require('../server/calendar');
  const evs = cal.parseICS(SAMPLE_ICS('20300105', '20300106'));
  assert.equal(evs.length, 3);
  const e1 = evs.find(e => e.uid === 'ev1@test');
  assert.equal(e1.title, 'Budget hearing, room 2');
  assert.ok(e1.description.includes('Line one\nLine two') && e1.description.includes('folded acrossmultiple'));
  assert.equal(e1.start, '2030-01-05T18:00:00.000Z'); assert.equal(e1.all_day, false);
  const e2 = evs.find(e => e.uid === 'ev2@test');
  assert.equal(e2.start, '2030-01-06'); assert.equal(e2.all_day, true); assert.equal(e2.recurring, true);
  const e3 = evs.find(e => e.uid === 'ev3@test');
  assert.equal(e3.end, '2020-01-01T10:30:00.000Z');

  const { db } = tmpDb();
  const p = db.createNode({ title: 'Proj' });
  const t = db.createNode({ parent_id: p.id, title: 'File report; by Friday', assignee: 'ai', due: '2030-02-10', mode: 'admin' });
  db.createNode({ parent_id: p.id, title: 'no due', assignee: 'human' });
  const v = cal.taskToVevent(db.getNode(t.id), p, 'http://x');
  assert.ok(v.includes('DTSTART;VALUE=DATE:20300210') && v.includes('DTEND;VALUE=DATE:20300211'));
  assert.ok(v.includes('SUMMARY:File report\\; by Friday (AI)'));
  const feed = cal.buildCalendar(db.dueTasks().map(x => cal.taskToVevent(x, x.project)).filter(Boolean));
  assert.equal((feed.match(/BEGIN:VEVENT/g) || []).length, 1);
  assert.deepEqual(cal.parseICS(feed).map(e => e.title), ['File report; by Friday (AI)'], 'feed round-trips through the parser');
});

test('calendar: subscribe, sync via harness, events query, agent tool, prep proposal, outbound feed over HTTP', async () => {
  const { db, path: dbPath } = tmpDb();
  const d1 = new Date(Date.now() + 2 * 86400e3), d2 = new Date(Date.now() + 4 * 86400e3);
  const ics = http.createServer((req, res) => { res.setHeader('content-type', 'text/calendar'); res.end(SAMPLE_ICS(compact(d1), compact(d2))); });
  await new Promise(r => ics.listen(0, r));
  const icsUrl = `http://127.0.0.1:${ics.address().port}/cal.ics`;

  const harness = createHarness(db, { dbPath, inProcess: true });
  const app = createApp(db, harness);
  const server = await new Promise(res => { const s = app.listen(0, () => res(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = (m, u, b) => new Promise((res, rej) => {
    const req = http.request(base + u, { method: m, headers: { 'content-type': 'application/json' } }, r => {
      let d = ''; r.on('data', c => d += c); r.on('end', () => res({ status: r.statusCode, headers: r.headers, body: d && r.headers['content-type']?.includes('json') ? JSON.parse(d) : d }));
    });
    req.on('error', rej); if (b) req.write(JSON.stringify(b)); req.end();
  });
  try {
    const p = (await call('POST', '/api/nodes', { title: 'Hearings', goal: 'g' })).body;
    db.createNode({ parent_id: p.id, title: 'Prep site visit notes', assignee: 'human' }); // covers "Site visit"
    const bad = await call('POST', '/api/calendars', { name: 'x', kind: 'nope', url: icsUrl });
    assert.equal(bad.status, 400);
    const c = (await call('POST', '/api/calendars', { name: 'Work', kind: 'ics', url: icsUrl, project_id: p.id })).body;
    const sync = (await call('POST', `/api/calendars/${c.id}/sync`)).body;
    assert.equal(sync.synced, 3);
    const evs = (await call('GET', '/api/events')).body;
    assert.deepEqual(evs.map(e => e.title).sort(), ['Budget hearing, room 2', 'Site visit'], 'old event outside window');
    assert.equal(db.calendars()[0].event_count, 3);

    // harness run: syncs calendars, agent sees events, proposes prep only for uncovered event
    const r = (await call('POST', '/api/harness/run', {})).body;
    assert.equal(r.calendars[0].synced, 3);
    const props = db.inbox().filter(i => i.type === 'new_task');
    assert.equal(props.length, 1);
    assert.ok(props[0].summary.includes('Budget hearing'));
    assert.equal(props[0].payload.mode, 'meeting'); assert.equal(props[0].payload.due, ymd(d1));
    db.acceptProposal(props[0].id);
    const prep = db.children(p.id).find(t => t.title.startsWith('Prepare for:'));
    assert.ok(prep && prep.mode === 'meeting' && prep.due === ymd(d1));

    // agent tool
    const { makeTools } = require('../harness/tools');
    const tools = makeTools({ db, project: db.getNode(p.id), task: prep });
    const te = await tools.call('calendar_events', {});
    assert.equal(te.events.length, 2); assert.equal(te.events[0].calendar, 'Work');

    // outbound feed: token-gated, contains the prep task
    const fu = (await call('GET', '/api/calendar/feed-url')).body;
    assert.ok(fu.url.endsWith('.ics') && fu.webcal.startsWith('webcal://'));
    const feed = await call('GET', new URL(fu.url).pathname);
    assert.equal(feed.status, 200); assert.ok(feed.headers['content-type'].includes('text/calendar'));
    assert.ok(feed.body.includes('Prepare for: Budget hearing'));
    assert.equal((await call('GET', '/calendar/wrongtoken.ics')).status, 404);
    const one = await call('GET', `/api/nodes/${prep.id}.ics`);
    assert.ok(one.headers['content-disposition'].includes('attachment'));
    await call('POST', '/api/calendar/feed-url/rotate');
    assert.equal((await call('GET', new URL(fu.url).pathname)).status, 404, 'rotated token invalidates old URL');

    // failing source records last_error, does not wipe cached events
    ics.close();
    await assert.rejects(harness.syncCalendar(c.id));
    assert.ok(db.getCalendar(c.id).last_error);
    assert.equal(db.events().length, 2);
  } finally { server.close(); try { ics.close(); } catch {} }
});
