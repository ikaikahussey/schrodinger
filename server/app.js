const express = require('express');
const path = require('node:path');

function createApp(db, harness) {
  const app = express();
  app.use(express.json({ limit: '2mb' }));
  app.use(express.static(path.join(__dirname, '..', 'public')));

  const wrap = fn => (req, res) => {
    try { const out = fn(req, res); if (out !== undefined) res.json(out); }
    catch (e) { res.status(400).json({ error: e.message }); }
  };

  app.get('/api/tree', wrap(() => db.tree()));
  app.get('/api/modes', wrap(() => db.MODES));
  app.get('/api/by-mode', wrap(req => db.byMode(req.query.assignee || null)));
  app.get('/api/nodes/:id', wrap(req => db.getNode(req.params.id)));
  app.post('/api/nodes', wrap(req => db.createNode(req.body, 'human')));
  app.patch('/api/nodes/:id', wrap(req => db.updateNode(req.params.id, req.body, 'human')));
  app.post('/api/nodes/:id/move', wrap(req => db.moveNode(req.params.id, req.body.parent_id || null, req.body.position ?? 0, 'human')));
  app.delete('/api/nodes/:id', wrap(req => { db.deleteNode(req.params.id); return { ok: true }; }));
  app.get('/api/nodes/:id/activity', wrap(req => db.activity(req.params.id)));
  app.get('/api/nodes/:id/digests', wrap(req => db.digests(req.params.id)));

  // Review flow
  app.post('/api/nodes/:id/approve', wrap(req => {
    const n = db.getNode(req.params.id);
    if (n.state !== 'review') throw new Error('task is not in review');
    return db.updateNode(n.id, { state: 'done' }, 'human', 'approved');
  }));
  app.post('/api/nodes/:id/reject', wrap(req => {
    const n = db.getNode(req.params.id);
    if (n.state !== 'review') throw new Error('task is not in review');
    const note = (req.body.note || '').trim();
    const combined = [n.acceptance_note, note && `[rejected ${new Date().toISOString().slice(0, 10)}] ${note}`].filter(Boolean).join('\n');
    return db.updateNode(n.id, { state: 'todo', acceptance_note: combined }, 'human', `rejected: ${note}`);
  }));

  // Inbox
  app.get('/api/inbox', wrap(req => db.inbox(req.query.status || 'open')));
  app.post('/api/inbox/:id/accept', wrap(req => { db.acceptProposal(req.params.id, req.body || {}); return { ok: true }; }));
  app.post('/api/inbox/:id/dismiss', wrap(req => { db.setProposalStatus(req.params.id, 'dismissed'); return { ok: true }; }));

  app.get('/api/activity', wrap(() => db.recentActivity()));
  app.post('/api/activity/:id/undo', wrap(req => db.undoActivity(Number(req.params.id))));

  // Harness controls
  app.get('/api/harness/status', wrap(() => ({ ...harness.status(), runs: db.runs() })));
  app.post('/api/harness/run', (req, res) => {
    harness.runOnce(req.body?.project_id || null)
      .then(r => res.json(r)).catch(e => res.status(500).json({ error: e.message }));
  });

  return app;
}

module.exports = { createApp };
