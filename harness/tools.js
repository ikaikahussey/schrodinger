// Tools available to a project sub-agent. Draft-only by construction: there is no tool that sends,
// posts, commits, or contacts anyone. File tools are jailed to workspace/<project_id>/.
const fs = require('node:fs');
const path = require('node:path');

const workspaceRoot = () => process.env.WORKSPACE_DIR || path.join(__dirname, '..', 'workspace');
const MAX_FETCH_BYTES = 200_000;
const MAX_FILE_BYTES = 500_000;

function makeTools({ db, project, task }) {
  const dir = path.join(workspaceRoot(), project.id);
  fs.mkdirSync(dir, { recursive: true });
  const safe = rel => {
    const p = path.resolve(dir, rel || '');
    if (p !== dir && !p.startsWith(dir + path.sep)) throw new Error('path escapes project workspace');
    return p;
  };

  const defs = [
    { name: 'project_context', description: 'Get the project goal, success criteria, constraints, and all tasks with their state, assignee, mode, due date, acceptance notes and existing artifacts.', input_schema: { type: 'object', properties: {} } },
    { name: 'web_fetch', description: 'Fetch a public URL and return its text content (HTML tags stripped, truncated). Read-only.', input_schema: { type: 'object', properties: { url: { type: 'string' } }, required: ['url'] } },
    { name: 'list_files', description: 'List files in this project\'s workspace.', input_schema: { type: 'object', properties: { subdir: { type: 'string' } } } },
    { name: 'read_file', description: 'Read a text file from this project\'s workspace.', input_schema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } },
    { name: 'write_file', description: 'Write a text file into this project\'s workspace (drafts, notes, data). Overwrites.', input_schema: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'] } },
    { name: 'calendar_events', description: 'List calendar events (from the owner\'s subscribed calendars) between two ISO dates. Defaults: today → +14 days. Read-only.', input_schema: { type: 'object', properties: { from: { type: 'string' }, to: { type: 'string' } } } },
    { name: 'finish', description: 'Submit the final draft for human review. Call exactly once when done.', input_schema: { type: 'object', properties: { artifact: { type: 'string', description: 'The deliverable text, markdown.' }, needs_from_human: { type: 'array', items: { type: 'string' } } }, required: ['artifact'] } },
  ];

  const handlers = {
    project_context() {
      const tasks = db.descendants(project.id).map(t => ({ id: t.id, title: t.title, assignee: t.assignee, state: t.state, mode: t.mode, due: t.due, acceptance_note: t.acceptance_note || undefined, artifact: t.artifact ? t.artifact.slice(0, 2000) : undefined, parent_id: t.parent_id === project.id ? undefined : t.parent_id }));
      return { project: { title: project.title, goal: project.goal, success_criteria: project.success_criteria, constraints: project.constraints }, current_task_id: task.id, tasks };
    },
    async web_fetch({ url }) {
      const u = new URL(url);
      if (!/^https?:$/.test(u.protocol)) throw new Error('http(s) only');
      const ctrl = new AbortController(); const to = setTimeout(() => ctrl.abort(), 20_000);
      try {
        const r = await fetch(u, { signal: ctrl.signal, redirect: 'follow', headers: { 'user-agent': 'schrodinger-agent/0.1' } });
        const ct = r.headers.get('content-type') || '';
        let text = await r.text();
        if (/html/.test(ct)) text = text.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/gi, '').replace(/<[^>]+>/g, ' ').replace(/&nbsp;|&#160;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n');
        if (text.length > MAX_FETCH_BYTES) text = text.slice(0, MAX_FETCH_BYTES) + '\n[truncated]';
        return { status: r.status, content_type: ct, text };
      } finally { clearTimeout(to); }
    },
    list_files({ subdir } = {}) {
      const base = safe(subdir);
      if (!fs.existsSync(base)) return { files: [] };
      const out = [];
      (function walk(d) { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else out.push({ path: path.relative(dir, p), bytes: fs.statSync(p).size }); } })(base);
      return { files: out };
    },
    read_file({ path: rel }) {
      const p = safe(rel);
      const st = fs.statSync(p);
      if (st.size > MAX_FILE_BYTES) throw new Error('file too large');
      return { path: rel, content: fs.readFileSync(p, 'utf8') };
    },
    write_file({ path: rel, content }) {
      const p = safe(rel);
      if (Buffer.byteLength(content) > MAX_FILE_BYTES) throw new Error('content too large');
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, content);
      return { path: rel, bytes: Buffer.byteLength(content) };
    },
    calendar_events({ from, to } = {}) {
      return { events: db.events({ from, to, project_id: project.id }).map(e => ({ title: e.title, start: e.start, end: e.end, all_day: !!e.all_day, location: e.location || undefined, calendar: e.calendar_name })) };
    },
    finish({ artifact, needs_from_human }) {
      return { done: true, artifact: needs_from_human?.length ? `${artifact}\n\n## Needs from you\n${needs_from_human.map(s => `- ${s}`).join('\n')}` : artifact };
    },
  };

  async function call(name, input) {
    if (!handlers[name]) throw new Error(`unknown tool ${name}`);
    return handlers[name](input || {});
  }

  return { defs, call, dir };
}

module.exports = { makeTools, workspaceRoot };
