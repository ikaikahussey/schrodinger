// Per-project sub-agent. Spawned by the harness as a separate process: `node agent.js <project_id>`.
// Scope: one project. Allowed to (a) execute its own AI-assigned leaf tasks → review with a draft artifact,
// (b) file proposals to the inbox, (c) write the project digest. Never changes structure or human tasks.

const { open } = require('../server/db');
const llm = require('./llm');

const cfg = () => ({ STALE_DAYS: Number(process.env.STALE_DAYS || 5), MAX_TASKS_PER_RUN: Number(process.env.MAX_TASKS_PER_RUN || 3) });

async function runProject(db, project_id, out = []) {
  const say = s => out.push(s);
  const { STALE_DAYS, MAX_TASKS_PER_RUN } = cfg();
  const project = await db.getNode(project_id);
  if (!project || project.kind !== 'project') throw new Error('not a project');
  if (project.project_status !== 'active') { say(`skip: project ${project.project_status}`); return out; }

  const all = await db.descendants(project_id);
  const parents = new Set(all.map(t => t.parent_id));
  const tasks = all.map(t => ({ ...t, has_children: parents.has(t.id) }));
  const leaves = tasks.filter(t => !t.has_children);
  const progress = await db.progress(project_id);

  // 1. Execute ready AI tasks.
  const readyAll = [];
  const aiTurn = t => (t.assignee === 'ai' && t.state === 'todo') || (t.assignee === 'shared' && t.ai_status === 'pending' && ['todo', 'in_progress'].includes(t.state));
  for (const t of leaves) if (aiTurn(t) && await db.depsSatisfied(t.id)) readyAll.push(t);
  const ready = readyAll
    .sort((a, b) => (a.due || '9999').localeCompare(b.due || '9999'))
    .slice(0, MAX_TASKS_PER_RUN);
  for (const t of ready) {
    await db.updateNode(t.id, { state: 'in_progress' }, 'ai', 'picked up by sub-agent');
    try {
      const { artifact, log } = await llm.draft({ db, project, task: t, siblings: tasks.filter(s => s.id !== t.id), rejectionNotes: t.acceptance_note, shared: t.assignee === 'shared' });
      if (t.assignee === 'shared') {
        // AI part done; task goes back to the human, who finishes it.
        await db.updateNode(t.id, { state: 'in_progress', ai_status: 'done', artifact }, 'ai', `AI part done — your turn (${log.length} tool calls)`);
      } else {
        await db.updateNode(t.id, { state: 'review', artifact }, 'ai', `draft ready for review (${log.length} tool calls)`);
      }
      say(`drafted: ${t.title}`);
    } catch (e) {
      await db.updateNode(t.id, { state: t.assignee === 'shared' ? t.state : 'todo' }, 'ai', `draft failed: ${e.message}`);
      say(`failed: ${t.title}: ${e.message}`);
    }
  }

  // 2. Blocked chains: tasks whose deps include a blocked task, or AI tasks waiting on a human task.
  const byId = Object.fromEntries(tasks.map(t => [t.id, t]));
  const waitingOnHuman = [];
  for (const t of leaves.filter(t => t.state !== 'done')) {
    const deps = (await db.getNode(t.id)).deps.map(d => byId[d]).filter(Boolean);
    if (deps.some(d => d.state === 'blocked')) {
      await db.propose(project_id, 'blocked_chain', `"${t.title}" is blocked by a blocked dependency`, { deps: deps.map(d => d.title) }, t.id);
    }
    if ((t.assignee === 'ai' || (t.assignee === 'shared' && t.ai_status === 'pending')) && deps.some(d => d.assignee === 'human' && d.state !== 'done')) waitingOnHuman.push(t);
  }

  // 3. Stale tasks.
  const cutoff = Date.now() - STALE_DAYS * 86400e3;
  for (const t of tasks.filter(t => t.state !== 'done' && new Date(t.last_activity_at).getTime() < cutoff)) {
    await db.propose(project_id, 'stale', `"${t.title}" has had no activity for ${STALE_DAYS}+ days`, {}, t.id);
  }

  // 4. Analysis proposals (decompose / new_task / reassign).
  const proposals = await llm.analyze({ project, tasks, progress });
  for (const p of proposals) await db.propose(project_id, p.type, p.summary, p.payload || {}, p.node_id || null);
  say(`proposals: ${proposals.length}`);

  // 4b. Calendar-driven proposals: upcoming events with no matching task → propose a prep task.
  const horizon = new Date(Date.now() + 7 * 86400e3).toISOString();
  // Only calendars linked to this project generate prep proposals; global calendars are visible to agents and digests but do not spawn tasks.
  const upcoming = (await db.events({ to: horizon, project_id })).filter(e => e.project_id === project_id);
  const norm = s => s.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  for (const e of upcoming) {
    const key = norm(e.title);
    const covered = tasks.some(t => norm(t.title).includes(key) || key.includes(norm(t.title)));
    if (!covered && key) {
      const due = e.start.slice(0, 10);
      await db.propose(project_id, 'new_task', `Calendar: "${e.title}" on ${due} has no related task — add a prep task?`,
        { title: `Prepare for: ${e.title}`, assignee: 'ai', due, mode: 'meeting' }, null);
    }
  }

  // 5. Digest.
  const fresh = await db.descendants(project_id);
  const day = new Date().toLocaleDateString('sv'); // local YYYY-MM-DD
  const grp = s => fresh.filter(t => t.state === s).map(t => `- ${t.title}`).join('\n') || '- none';
  const needsYou = [
    ...fresh.filter(t => t.state === 'review').map(t => `- review: ${t.title}`),
    ...fresh.filter(t => t.assignee === 'shared' && t.ai_status === 'done' && t.state !== 'done').map(t => `- your part: ${t.title}`),
    ...fresh.filter(t => t.assignee === 'human' && t.state === 'todo' && t.due && t.due <= day).map(t => `- overdue: ${t.title} (${t.due})`),
    ...waitingOnHuman.map(t => `- AI waiting on your task before: ${t.title}`),
  ].join('\n') || '- nothing';
  const p2 = await db.progress(project_id);
  const todayEvents = (await db.events({ from: day, to: new Date(Date.now() + 86400e3).toLocaleDateString('sv'), project_id })).map(e => `- ${e.all_day ? 'all day' : new Date(e.start).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}: ${e.title}`).join('\n');
  const body = `# ${project.title} — ${day}\nProgress: ${p2.done}/${p2.total} (${p2.pct}%)\n\n## Done\n${grp('done')}\n\n## In progress\n${grp('in_progress')}\n\n## Blocked\n${grp('blocked')}\n\n## Needs you\n${needsYou}${todayEvents ? `\n\n## Today's calendar\n${todayEvents}` : ''}`;
  await db.saveDigest(project_id, day, body);
  say(`digest written`);
  return out;
}

if (require.main === module) {
  const project_id = process.argv[2];
  open().then(db => runProject(db, project_id).then(out => { process.stdout.write(out.join('\n') + '\n'); return db.close(); }).then(() => process.exit(0))
    .catch(e => { process.stderr.write(e.stack + '\n'); process.exit(1); }));
}

module.exports = { runProject };
