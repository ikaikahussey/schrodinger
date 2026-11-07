// Master harness: on a schedule (and on demand), spawns one sub-agent process per active project.
const { spawn } = require('node:child_process');
const path = require('node:path');

function createHarness(db, { dbPath, intervalMs = Number(process.env.HARNESS_INTERVAL_MS || 5 * 60e3), inProcess = false } = {}) {
  let timer = null, running = false, lastRun = null, lastResults = [];

  function spawnAgent(project_id) {
    return new Promise(resolve => {
      const child = spawn(process.execPath, [path.join(__dirname, 'agent.js'), project_id], {
        env: { ...process.env, DB_PATH: dbPath }, stdio: ['ignore', 'pipe', 'pipe'],
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

  async function runOnce(project_id = null) {
    if (running) return { skipped: true, reason: 'already running' };
    running = true;
    try {
      const projects = db.children(null).filter(p => p.project_status === 'active' && (!project_id || p.id === project_id));
      const results = await Promise.all(projects.map(async p => {
        const runId = db.startRun(p.id);
        const r = inProcess ? await runProjectInProcess(p.id) : await spawnAgent(p.id);
        db.finishRun(runId, r.code === 0 ? 'ok' : 'error', [r.out, r.err].filter(Boolean).join('\n'));
        return { project_id: p.id, title: p.title, ...r };
      }));
      lastRun = new Date().toISOString(); lastResults = results;
      return { ran: results.length, results };
    } finally { running = false; }
  }

  function start() { if (!timer) { timer = setInterval(() => runOnce().catch(() => {}), intervalMs); } }
  function stop() { if (timer) { clearInterval(timer); timer = null; } }
  function status() { return { scheduled: !!timer, intervalMs, running, lastRun, lastResults, live: require('./llm').live() }; }

  return { runOnce, start, stop, status };
}

module.exports = { createHarness };
