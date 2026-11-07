// Master harness: on a schedule (and on demand), spawns one sub-agent process per active project.
const { spawn } = require('node:child_process');
const path = require('node:path');

function createHarness(db, { intervalMs = Number(process.env.HARNESS_INTERVAL_MS || 5 * 60e3), inProcess = !process.env.DATABASE_URL || !!process.env.VERCEL || process.env.HARNESS_INPROCESS === '1' } = {}) {
  let timer = null, running = false, lastRun = null, lastResults = [];

  function spawnAgent(project_id) {
    return new Promise(resolve => {
      const child = spawn(process.execPath, [path.join(__dirname, 'agent.js'), project_id], {
        env: { ...process.env }, stdio: ['ignore', 'pipe', 'pipe'],
      });
      let out = '', err = '';
      child.stdout.on('data', d => out += d);
      child.stderr.on('data', d => err += d);
      child.on('close', code => resolve({ code, out: out.trim(), err: err.replace(/\(node:\d+\) ExperimentalWarning[^\n]*\n(\(Use[^\n]*\n)?/g, '').trim() }));
    });
  }

  async function runProjectInProcess(project_id) {
    const { runProject } = require('./agent');
    try { const out = await runProject(db, project_id); return { code: 0, out: out.join('\n'), err: '' }; }
    catch (e) { return { code: 1, out: '', err: e.message }; }
  }

  // Pull external calendars (in-process, before sub-agents run).
  async function syncCalendar(id) {
    const cal = require('../server/calendar');
    const c = await db.getCalendar(id); if (!c) throw new Error('calendar not found');
    try {
      const evs = await cal.providers[c.kind].fetchEvents(c);
      await db.replaceEvents(c.id, evs);
      return { id: c.id, synced: evs.length };
    } catch (e) { await db.updateCalendar(c.id, { last_error: e.message }); throw e; }
  }
  async function syncAllCalendars() {
    const out = [];
    for (const c of (await db.calendars()).filter(c => c.enabled)) {
      try { out.push(await syncCalendar(c.id)); } catch (e) { out.push({ id: c.id, error: e.message }); }
    }
    return out;
  }

  async function runOnce(project_id = null) {
    if (running) return { skipped: true, reason: 'already running' };
    running = true;
    try {
      const calendars = await syncAllCalendars();
      const projects = (await db.children(null)).filter(p => p.project_status === 'active' && (!project_id || p.id === project_id));
      const results = await Promise.all(projects.map(async p => {
        const runId = await db.startRun(p.id);
        const r = inProcess ? await runProjectInProcess(p.id) : await spawnAgent(p.id);
        await db.finishRun(runId, r.code === 0 ? 'ok' : 'error', [r.out, r.err].filter(Boolean).join('\n'));
        return { project_id: p.id, title: p.title, ...r };
      }));
      lastRun = new Date().toISOString(); lastResults = results;
      return { ran: results.length, results, calendars };
    } finally { running = false; }
  }

  function start() { if (!timer) { timer = setInterval(() => runOnce().catch(() => {}), intervalMs); } }
  function stop() { if (timer) { clearInterval(timer); timer = null; } }
  function status() { return { scheduled: !!timer, intervalMs, running, lastRun, lastResults, live: require('./llm').live(), inProcess }; }

  return { runOnce, start, stop, status, syncCalendar, syncAllCalendars };
}

module.exports = { createHarness };
