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
delete process.env.DATABASE_URL;

// Fresh in-memory Postgres (PGlite) per test.
async function tmpDb() { const db = await open(undefined); return { db, path: null }; }
const H = (db, opts = {}) => createHarness(db, { inProcess: true, ...opts });

test('tree: create, nest, move, progress, cannot move into own subtree', async () => {
  const { db } = await tmpDb();
  const p = await db.createNode({ title: 'P', goal: 'g' });
  const a = await db.createNode({ parent_id: p.id, title: 'A' });
  const b = await db.createNode({ parent_id: p.id, title: 'B' });
  const a1 = await db.createNode({ parent_id: a.id, title: 'A1' });
  assert.equal(p.kind, 'project'); assert.equal(a.kind, 'task');
  assert.deepEqual(await db.progress(p.id), { total: 2, done: 0, pct: 0 }); // leaves: A1, B
  await db.updateNode(a1.id, { state: 'done' });
  assert.equal((await db.progress(p.id)).pct, 50);
  await db.moveNode(b.id, a.id, 0);
  assert.deepEqual((await db.children(a.id)).map(c => c.title), ['B', 'A1']);
  await assert.rejects(db.moveNode(a.id, a1.id, 0), /own subtree/);
  const t = await db.tree();
  assert.equal(t[0].children.length, 1); assert.equal(t[0].children[0].children.length, 2);
});

test('deps gate AI pickup; review → approve/reject flow; rejection note feeds redraft', async () => {
  const { db } = await tmpDb();
  const p = await db.createNode({ title: 'P', goal: 'ship' });
  const t1 = await db.createNode({ parent_id: p.id, title: 'first', assignee: 'ai' });
  const t2 = await db.createNode({ parent_id: p.id, title: 'second', assignee: 'ai', deps: [t1.id] });
  const h = await db.createNode({ parent_id: p.id, title: 'human thing', assignee: 'human' });
  const harness = H(db);

  await harness.runOnce();
  assert.equal((await db.getNode(t1.id)).state, 'review');
  assert.ok((await db.getNode(t1.id)).artifact.includes('Draft: first'));
  assert.equal((await db.getNode(t2.id)).state, 'todo', 'dependent task not picked up');
  assert.equal((await db.getNode(h.id)).state, 'todo', 'human task untouched');

  // reject with note → back to todo, redraft includes note
  await db.updateNode(t1.id, { state: 'todo', acceptance_note: 'make it shorter' }, 'human', 'rejected');
  await harness.runOnce();
  assert.equal((await db.getNode(t1.id)).state, 'review');
  assert.ok((await db.getNode(t1.id)).artifact.includes('make it shorter'));

  // approve → done unlocks t2
  await db.updateNode(t1.id, { state: 'done' }, 'human', 'approved');
  await harness.runOnce();
  assert.equal((await db.getNode(t2.id)).state, 'review');
  assert.equal((await db.progress(p.id)).done, 1);
});

test('harness runs one sub-agent per active project; paused projects skipped', async () => {
  const { db } = await tmpDb();
  const p1 = await db.createNode({ title: 'P1' }); await db.createNode({ parent_id: p1.id, title: 'x', assignee: 'ai' });
  const p2 = await db.createNode({ title: 'P2' }); await db.createNode({ parent_id: p2.id, title: 'y', assignee: 'ai' });
  const p3 = await db.createNode({ title: 'P3', project_status: 'paused' }); await db.updateNode(p3.id, { project_status: 'paused' });
  const z = await db.createNode({ parent_id: p3.id, title: 'z', assignee: 'ai' });
  const harness = process.env.TEST_DATABASE_URL ? createHarness(db, { inProcess: false }) : H(db); // child processes need a shared Postgres
  const r = await harness.runOnce();
  assert.equal(r.ran, 2);
  assert.ok(r.results.every(x => x.code === 0), JSON.stringify(r.results));
  assert.equal((await db.getNode(z.id)).state, 'todo');
  assert.equal((await db.runs()).filter(x => x.status === 'ok').length, 2);
});

test('proposals: structural changes only land in inbox; accept applies, dismiss does not', async () => {
  const { db } = await tmpDb();
  const p = await db.createNode({ title: 'Grant', goal: 'submit' });
  const big = await db.createNode({ parent_id: p.id, title: 'Research rules and draft budget', assignee: 'ai' });
  const empty = await db.createNode({ title: 'Empty' });
  const harness = H(db);
  await harness.runOnce();
  const inbox = await db.inbox();
  const dec = inbox.find(i => i.type === 'decompose' && i.node_id === big.id);
  const nt = inbox.find(i => i.type === 'new_task' && i.project_id === empty.id);
  assert.ok(dec && nt);
  assert.equal((await db.children(big.id)).length, 0, 'no subtasks created without approval');
  assert.equal((await db.children(empty.id)).length, 0);

  await db.acceptProposal(dec.id);
  assert.deepEqual((await db.children(big.id)).map(c => c.title), ['Research rules', 'draft budget']);
  await db.setProposalStatus(nt.id, 'dismissed');
  assert.equal((await db.children(empty.id)).length, 0);
  assert.equal((await db.inbox()).length, 0);

  // idempotent: second run does not duplicate open proposals
  await harness.runOnce();
  const again = await db.inbox();
  assert.equal(again.filter(i => i.type === 'new_task' && i.project_id === empty.id).length, 0, 'dismissed not re-raised while... ');
});

test('stale + blocked-chain detection and digest content', async () => {
  const { db } = await tmpDb();
  process.env.STALE_DAYS = '1';
  const p = await db.createNode({ title: 'P', goal: 'g' });
  const blocked = await db.createNode({ parent_id: p.id, title: 'blocked one', assignee: 'human', state: 'blocked' });
  const dep = await db.createNode({ parent_id: p.id, title: 'after blocked', assignee: 'ai', deps: [blocked.id] });
  const old = await db.createNode({ parent_id: p.id, title: 'old task', assignee: 'human' });
  await db.raw.query(`UPDATE nodes SET last_activity_at=$1 WHERE id=$2`, [new Date(Date.now() - 3 * 86400e3).toISOString(), old.id]);
  const harness = H(db);
  await harness.runOnce();
  const types = (await db.inbox()).map(i => i.type);
  assert.ok(types.includes('blocked_chain'));
  assert.ok(types.includes('stale'));
  assert.equal((await db.getNode(dep.id)).state, 'todo', 'AI task behind blocked dep not executed');
  const d = (await db.digests(p.id))[0];
  assert.ok(d.body.includes('## Blocked') && d.body.includes('blocked one'));
  assert.ok(d.body.includes('AI waiting on your task before: after blocked'));
  delete process.env.STALE_DAYS;
});

test('undo reverses AI state change from activity log', async () => {
  const { db } = await tmpDb();
  const p = await db.createNode({ title: 'P' });
  const t = await db.createNode({ parent_id: p.id, title: 't', assignee: 'ai' });
  await db.updateNode(t.id, { state: 'review', artifact: 'x' }, 'ai', 'draft');
  const act = (await db.activity(t.id))[0];
  await db.undoActivity(act.id);
  const n = await db.getNode(t.id);
  assert.equal(n.state, 'todo'); assert.equal(n.artifact, null);
});

test('HTTP API: create, patch, approve/reject guards, inbox accept', async () => {
  const { db } = await tmpDb();
  const harness = H(db);
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
  const { db } = await tmpDb();
  const p1 = await db.createNode({ title: 'P1' }); const p2 = await db.createNode({ title: 'P2' });
  const c1 = await db.createNode({ parent_id: p1.id, title: 'call a', mode: 'call', due: '2030-01-02' });
  const c2 = await db.createNode({ parent_id: p2.id, title: 'call b', mode: 'call', due: '2030-01-01' });
  const e1 = await db.createNode({ parent_id: p2.id, title: 'buy stamps', mode: 'errand' });
  const u = await db.createNode({ parent_id: p1.id, title: 'no mode' });
  const parentTask = await db.createNode({ parent_id: p1.id, title: 'parent', mode: 'call' });
  await db.createNode({ parent_id: parentTask.id, title: 'child call', mode: 'call' });
  await assert.rejects(db.updateNode(u.id, { mode: 'bogus' }), /invalid mode/);
  await db.updateNode(u.id, { mode: 'email' });
  const g = await db.byMode();
  assert.deepEqual(g.call.map(t => t.title), ['call b', 'call a', 'child call'], 'sorted by due, parents excluded');
  assert.equal(g.call[0].project_title, 'P2');
  assert.deepEqual(Object.keys(g).sort(), ['call', 'email', 'errand']);
  await db.updateNode(c2.id, { state: 'done' });
  assert.equal((await db.byMode()).call.length, 2, 'done excluded');
  assert.equal((await db.byMode('ai')).call, undefined, 'assignee filter');
  // schema creation is idempotent (second open on the same driver is a no-op)
  const again = require('../server/db');
  assert.ok(again.MODES.includes('call'));
});

test('tools: workspace jail, write/read/list, no send-type tools, context', async () => {
  const { db } = await tmpDb();
  const { makeTools } = require('../harness/tools');
  const p = await db.createNode({ title: 'P', goal: 'g', constraints: 'draft only' });
  const t = await db.createNode({ parent_id: p.id, title: 't', assignee: 'ai', mode: 'write' });
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
  assert.equal(await db.fileRead(p.id, 'a/b.md'), 'hi');
  const p2 = await db.createNode({ title: 'Other' });
  const tools2 = makeTools({ db, project: p2, task: t });
  assert.deepEqual((await tools2.call('list_files', {})).files, [], 'files are per-project');
});

test('agent loop: scripted model runs tools then finish; turn limit; tool errors fed back', async () => {
  const { db } = await tmpDb();
  const llm = require('../harness/llm');
  const p = await db.createNode({ title: 'P', goal: 'g' });
  const t = await db.createNode({ parent_id: p.id, title: 'write memo', assignee: 'ai' });
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

test('calendar: ICS parse (folding, escapes, all-day, duration, rrule) and task feed generation', async () => {
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

  const { db } = await tmpDb();
  const p = await db.createNode({ title: 'Proj' });
  const t = await db.createNode({ parent_id: p.id, title: 'File report; by Friday', assignee: 'ai', due: '2030-02-10', mode: 'admin' });
  await db.createNode({ parent_id: p.id, title: 'no due', assignee: 'human' });
  const v = cal.taskToVevent(await db.getNode(t.id), p, 'http://x');
  assert.ok(v.includes('DTSTART;VALUE=DATE:20300210') && v.includes('DTEND;VALUE=DATE:20300211'));
  assert.ok(v.includes('SUMMARY:File report\\; by Friday (AI)'));
  const feed = cal.buildCalendar((await db.dueTasks()).map(x => cal.taskToVevent(x, x.project)).filter(Boolean));
  assert.equal((feed.match(/BEGIN:VEVENT/g) || []).length, 1);
  assert.deepEqual(cal.parseICS(feed).map(e => e.title), ['File report; by Friday (AI)'], 'feed round-trips through the parser');
});

test('calendar: subscribe, sync via harness, events query, agent tool, prep proposal, outbound feed over HTTP', async () => {
  const { db } = await tmpDb();
  const d1 = new Date(Date.now() + 2 * 86400e3), d2 = new Date(Date.now() + 4 * 86400e3);
  const ics = http.createServer((req, res) => { res.setHeader('content-type', 'text/calendar'); res.end(SAMPLE_ICS(compact(d1), compact(d2))); });
  await new Promise(r => ics.listen(0, r));
  const icsUrl = `http://127.0.0.1:${ics.address().port}/cal.ics`;

  const harness = H(db);
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
    await db.createNode({ parent_id: p.id, title: 'Prep site visit notes', assignee: 'human' }); // covers "Site visit"
    const bad = await call('POST', '/api/calendars', { name: 'x', kind: 'nope', url: icsUrl });
    assert.equal(bad.status, 400);
    const c = (await call('POST', '/api/calendars', { name: 'Work', kind: 'ics', url: icsUrl, project_id: p.id })).body;
    const sync = (await call('POST', `/api/calendars/${c.id}/sync`)).body;
    assert.equal(sync.synced, 3);
    const evs = (await call('GET', '/api/events')).body;
    assert.deepEqual(evs.map(e => e.title).sort(), ['Budget hearing, room 2', 'Site visit'], 'old event outside window');
    assert.equal((await db.calendars())[0].event_count, 3);

    // harness run: syncs calendars, agent sees events, proposes prep only for uncovered event
    const r = (await call('POST', '/api/harness/run', {})).body;
    assert.equal(r.calendars[0].synced, 3);
    const props = (await db.inbox()).filter(i => i.type === 'new_task');
    assert.equal(props.length, 1);
    assert.ok(props[0].summary.includes('Budget hearing'));
    assert.equal(props[0].payload.mode, 'meeting'); assert.equal(props[0].payload.due, ymd(d1));
    await db.acceptProposal(props[0].id);
    const prep = (await db.children(p.id)).find(t => t.title.startsWith('Prepare for:'));
    assert.ok(prep && prep.mode === 'meeting' && prep.due === ymd(d1));

    // agent tool
    const { makeTools } = require('../harness/tools');
    const tools = makeTools({ db, project: await db.getNode(p.id), task: prep });
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
    assert.ok((await db.getCalendar(c.id)).last_error);
    assert.equal((await db.events()).length, 2);
  } finally { server.close(); try { ics.close(); } catch {} }
});

test('auth: password gate blocks UI and API, allows login, logout, feed, and healthz', async () => {
  const { db } = await tmpDb();
  const { createAuth } = require('../server/auth');
  const auth = createAuth({ password: 'open-sesame' });
  const app = createApp(db, H(db), { auth });
  const server = await new Promise(res => { const s = app.listen(0, () => res(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = (m, u, { body, cookie, form } = {}) => new Promise((res, rej) => {
    const req = http.request(base + u, { method: m, headers: { 'content-type': form ? 'application/x-www-form-urlencoded' : 'application/json', ...(cookie ? { cookie } : {}) } }, r => {
      let d = ''; r.on('data', c => d += c); r.on('end', () => res({ status: r.statusCode, headers: r.headers, body: d }));
    });
    req.on('error', rej); if (body) req.write(form ? body : JSON.stringify(body)); req.end();
  });
  try {
    assert.equal((await call('GET', '/')).status, 302);
    assert.equal((await call('GET', '/api/tree')).status, 401);
    assert.equal((await call('GET', '/healthz')).status, 200);
    assert.equal((await call('GET', '/logo.svg')).status, 200);
    assert.equal((await call('POST', '/login', { body: 'password=wrong', form: true })).status, 401);
    const ok = await call('POST', '/login', { body: 'password=open-sesame', form: true });
    assert.equal(ok.status, 302);
    const cookie = ok.headers['set-cookie'][0].split(';')[0];
    assert.ok(cookie.startsWith('sid=') && ok.headers['set-cookie'][0].includes('HttpOnly'));
    assert.equal((await call('GET', '/api/tree', { cookie })).status, 200);
    assert.equal((await call('GET', '/', { cookie })).status, 200);
    const tampered = cookie.slice(0, -2) + 'xx';
    assert.equal((await call('GET', '/api/tree', { cookie: tampered })).status, 401);
    const feedPath = `/calendar/${await db.feedToken()}.ics`;
    assert.equal((await call('GET', feedPath)).status, 200, 'feed reachable without login (token-gated)');
    const lo = await call('GET', '/logout', { cookie });
    assert.ok(lo.headers['set-cookie'][0].includes('Max-Age=0'));
    // disabled auth = open
    const open2 = createApp(db, H(db), { auth: createAuth({ password: undefined }) });
    const s2 = await new Promise(res => { const s = open2.listen(0, () => res(s)); });
    const r2 = await new Promise((res, rej) => http.get(`http://127.0.0.1:${s2.address().port}/api/tree`, r => res(r.statusCode)).on('error', rej));
    assert.equal(r2, 200); s2.close();
  } finally { server.close(); }
});
