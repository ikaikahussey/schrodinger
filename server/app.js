const express = require('express');
const path = require('node:path');
const cal = require('./calendar');

const { createAuth } = require('./auth');

function createApp(db, harness, { auth = createAuth() } = {}) {
  const app = express();
  app.set('trust proxy', 1);
  app.use(express.json({ limit: '2mb' }));
  app.use(express.urlencoded({ extended: false }));
  app.use(auth.middleware);
  const INDEX = require('node:fs').readFileSync(path.join(__dirname, 'views', 'index.html'), 'utf8');
  app.get('/', (req, res) => res.type('html').send(INDEX));
  app.use(express.static(path.join(__dirname, '..', 'public')));
  app.get('/healthz', (req, res) => res.json({ ok: true }));

  const wrap = fn => async (req, res) => {
    try { const out = await fn(req, res); if (out !== undefined) res.json(out); }
    catch (e) { res.status(400).json({ error: e.message }); }
  };

  app.get('/api/tree', wrap(() => db.tree()));
  app.get('/api/modes', wrap(() => db.MODES));
  app.get('/api/by-mode', wrap(req => db.byMode(req.query.assignee || null)));
  app.get('/api/nodes/:id.ics', async (req, res) => {
    const t = await db.getNode(req.params.id); if (!t) return res.status(404).end();
    const v = cal.taskToVevent(t, await db.projectOf(t.id), `${req.protocol}://${req.get('host')}`);
    if (!v) return res.status(400).json({ error: 'task has no due date' });
    res.set('content-type', 'text/calendar; charset=utf-8').set('content-disposition', `attachment; filename="task-${t.id.slice(0, 8)}.ics"`).send(cal.buildCalendar([v], t.title));
  });
  app.get('/api/nodes/:id', wrap(req => db.getNode(req.params.id)));
  app.post('/api/nodes', wrap(req => db.createNode(req.body, 'human')));
  app.patch('/api/nodes/:id', wrap(req => db.updateNode(req.params.id, req.body, 'human')));
  app.post('/api/nodes/:id/move', wrap(req => db.moveNode(req.params.id, req.body.parent_id || null, req.body.position ?? 0, 'human')));
  app.delete('/api/nodes/:id', wrap(async req => { await db.deleteNode(req.params.id); return { ok: true }; }));
  app.get('/api/nodes/:id/activity', wrap(req => db.activity(req.params.id)));
  app.get('/api/nodes/:id/digests', wrap(req => db.digests(req.params.id)));

  // Review flow
  app.post('/api/nodes/:id/approve', wrap(async req => {
    const n = await db.getNode(req.params.id);
    if (n.state !== 'review') throw new Error('task is not in review');
    return db.updateNode(n.id, { state: 'done' }, 'human', 'approved');
  }));
  app.post('/api/nodes/:id/reject', wrap(async req => {
    const n = await db.getNode(req.params.id);
    if (n.state !== 'review') throw new Error('task is not in review');
    const note = (req.body.note || '').trim();
    const combined = [n.acceptance_note, note && `[rejected ${new Date().toISOString().slice(0, 10)}] ${note}`].filter(Boolean).join('\n');
    return db.updateNode(n.id, { state: 'todo', acceptance_note: combined }, 'human', `rejected: ${note}`);
  }));

  // Shared tasks: send back to the AI for another pass
  app.post('/api/nodes/:id/redo-ai', wrap(async req => {
    const n = await db.getNode(req.params.id);
    if (n.assignee !== 'shared') throw new Error('task is not shared');
    const note = (req.body.note || '').trim();
    const combined = [n.acceptance_note, note && `[sent back ${new Date().toISOString().slice(0, 10)}] ${note}`].filter(Boolean).join('\n');
    return db.updateNode(n.id, { ai_status: 'pending', acceptance_note: combined }, 'human', `sent back to AI: ${note}`);
  }));

  // Inbox
  app.get('/api/inbox', wrap(req => db.inbox(req.query.status || 'open')));
  app.post('/api/inbox/:id/accept', wrap(async req => { await db.acceptProposal(req.params.id, req.body || {}); return { ok: true }; }));
  app.post('/api/inbox/:id/dismiss', wrap(async req => { await db.setProposalStatus(req.params.id, 'dismissed'); return { ok: true }; }));

  app.get('/api/activity', wrap(() => db.recentActivity()));
  app.post('/api/activity/:id/undo', wrap(req => db.undoActivity(Number(req.params.id))));

  // Calendar: outbound feed (subscribe URL) + per-task ics
  app.get('/calendar/:token.ics', async (req, res) => {
    if (req.params.token !== await db.feedToken()) return res.status(404).end();
    const base = `${req.protocol}://${req.get('host')}`;
    const vevents = (await db.dueTasks()).map(t => cal.taskToVevent(t, t.project, base)).filter(Boolean);
    res.set('content-type', 'text/calendar; charset=utf-8').send(cal.buildCalendar(vevents));
  });
  app.get('/api/calendar/feed-url', wrap(async req => { const tok = await db.feedToken(); return { url: `${req.protocol}://${req.get('host')}/calendar/${tok}.ics`, webcal: `webcal://${req.get('host')}/calendar/${tok}.ics` }; }));
  app.post('/api/calendar/feed-url/rotate', wrap(async () => { await db.setSetting('feed_token', require('node:crypto').randomBytes(16).toString('hex')); return { ok: true }; }));
  // Calendar: inbound subscriptions
  app.get('/api/calendars', wrap(() => db.calendars()));
  app.post('/api/calendars', wrap(req => {
    const { name, kind = 'ics', url, project_id } = req.body;
    if (!name || !url) throw new Error('name and url required');
    if (!cal.providers[kind]) throw new Error(`unknown kind; one of ${Object.keys(cal.providers).join(', ')}`);
    return db.addCalendar({ name, kind, url, project_id: project_id || null });
  }));
  app.patch('/api/calendars/:id', wrap(req => db.updateCalendar(req.params.id, req.body)));
  app.delete('/api/calendars/:id', wrap(async req => { await db.deleteCalendar(req.params.id); return { ok: true }; }));
  app.post('/api/calendars/:id/sync', (req, res) => {
    harness.syncCalendar(req.params.id).then(r => res.json(r)).catch(e => res.status(400).json({ error: e.message }));
  });
  app.get('/api/events', wrap(req => db.events({ from: req.query.from, to: req.query.to, project_id: req.query.project_id || null })));

  // Harness controls
  app.get('/api/harness/status', wrap(async () => ({ ...harness.status(), auth: auth.enabled, runs: await db.runs() })));
  // Scheduled entry point (Vercel Cron sends Authorization: Bearer $CRON_SECRET)
  app.get('/api/harness/cron', (req, res) => {
    const secret = process.env.CRON_SECRET;
    if (secret && req.get('authorization') !== `Bearer ${secret}`) return res.status(401).json({ error: 'unauthorized' });
    harness.runOnce().then(r => res.json(r)).catch(e => res.status(500).json({ error: e.message }));
  });
  app.post('/api/harness/run', (req, res) => {
    harness.runOnce(req.body?.project_id || null)
      .then(r => res.json(r)).catch(e => res.status(500).json({ error: e.message }));
  });

  return app;
}

module.exports = { createApp };
